package launcher

import (
	"syscall"
	"unsafe"
)

var (
	pdh                              = syscall.NewLazyDLL("pdh.dll")
	procPdhOpenQueryW                = pdh.NewProc("PdhOpenQueryW")
	procPdhAddEnglishCounterW        = pdh.NewProc("PdhAddEnglishCounterW")
	procPdhCollectQueryData          = pdh.NewProc("PdhCollectQueryData")
	procPdhGetFormattedCounterArrayW = pdh.NewProc("PdhGetFormattedCounterArrayW")
	procPdhCloseQuery                = pdh.NewProc("PdhCloseQuery")

	procK32GetProcessMemoryInfo = kernel32.NewProc("K32GetProcessMemoryInfo")
)

const (
	pdhFmtLarge                    = 0x00000400
	pdhMoreData                    = 0x800007D2
	pdhCStatusNewData              = 1
	processQueryLimitedInformation = 0x1000
)

// pdhFmtCounterValueItem is PDH_FMT_COUNTERVALUE_ITEM_W read with PDH_FMT_LARGE.
type pdhFmtCounterValueItem struct {
	name   *uint16
	status uint32
	_      uint32
	value  int64
}

// readGPUCounters samples the per-process and per-adapter dedicated GPU memory counters.
// Both are raw byte counts, so a single collection is enough.
func readGPUCounters(pid int) (gpuCounters, bool) {
	var query uintptr
	if r, _, _ := procPdhOpenQueryW.Call(0, 0, uintptr(unsafe.Pointer(&query))); r != 0 {
		return gpuCounters{}, false
	}
	defer procPdhCloseQuery.Call(query)
	add := func(path string) (uintptr, bool) {
		p, err := syscall.UTF16PtrFromString(path)
		if err != nil {
			return 0, false
		}
		var counter uintptr
		r, _, _ := procPdhAddEnglishCounterW.Call(query, uintptr(unsafe.Pointer(p)), 0, uintptr(unsafe.Pointer(&counter)))
		return counter, r == 0
	}
	procCounter, ok1 := add(`\GPU Process Memory(*)\Dedicated Usage`)
	adapterCounter, ok2 := add(`\GPU Adapter Memory(*)\Dedicated Usage`)
	if !ok1 || !ok2 {
		return gpuCounters{}, false
	}
	if r, _, _ := procPdhCollectQueryData.Call(query); r != 0 {
		return gpuCounters{}, false
	}
	c := gpuCounters{engine: map[string]uint64{}, adapter: map[string]uint64{}}
	okProc := readCounterArray(procCounter, func(name string, v uint64) {
		if p, a := splitGPUCounterName(name); p == pid && a != "" {
			c.engine[a] += v
		}
	})
	okAdapter := readCounterArray(adapterCounter, func(name string, v uint64) { c.adapter[name] += v })
	return c, okProc && okAdapter
}

// readCounterArray calls fn for every instance of a wildcard counter.
func readCounterArray(counter uintptr, fn func(name string, value uint64)) bool {
	for range 3 { // instances can appear between the size query and the read
		var size, count uint32
		r, _, _ := procPdhGetFormattedCounterArrayW.Call(counter, pdhFmtLarge,
			uintptr(unsafe.Pointer(&size)), uintptr(unsafe.Pointer(&count)), 0)
		if uint32(r) != pdhMoreData {
			return r == 0 && count == 0
		}
		buf := make([]uint64, size/8+1) // uint64 keeps the items 8-byte aligned
		r, _, _ = procPdhGetFormattedCounterArrayW.Call(counter, pdhFmtLarge,
			uintptr(unsafe.Pointer(&size)), uintptr(unsafe.Pointer(&count)), uintptr(unsafe.Pointer(&buf[0])))
		if uint32(r) == pdhMoreData {
			continue
		}
		if r != 0 {
			return false
		}
		items := unsafe.Slice((*pdhFmtCounterValueItem)(unsafe.Pointer(&buf[0])), count)
		for _, it := range items {
			if it.status <= pdhCStatusNewData && it.value > 0 {
				fn(utf16PtrToString(it.name), uint64(it.value))
			}
		}
		return true
	}
	return false
}

func utf16PtrToString(p *uint16) string {
	if p == nil {
		return ""
	}
	n := 0
	for ptr := unsafe.Pointer(p); *(*uint16)(ptr) != 0; ptr = unsafe.Add(ptr, 2) {
		n++
	}
	return syscall.UTF16ToString(unsafe.Slice(p, n))
}

type processMemoryCounters struct {
	cb                         uint32
	pageFaultCount             uint32
	peakWorkingSetSize         uintptr
	workingSetSize             uintptr
	quotaPeakPagedPoolUsage    uintptr
	quotaPagedPoolUsage        uintptr
	quotaPeakNonPagedPoolUsage uintptr
	quotaNonPagedPoolUsage     uintptr
	pagefileUsage              uintptr
	peakPagefileUsage          uintptr
}

// processRSSMB returns the working set of pid, Windows' counterpart of VmRSS.
func processRSSMB(pid int) int {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return 0
	}
	defer syscall.CloseHandle(h)
	var pmc processMemoryCounters
	pmc.cb = uint32(unsafe.Sizeof(pmc))
	if r, _, _ := procK32GetProcessMemoryInfo.Call(uintptr(h), uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.cb)); r == 0 {
		return 0
	}
	return int(pmc.workingSetSize >> 20)
}
