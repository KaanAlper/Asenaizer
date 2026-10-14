package launcher

import (
	"sort"
	"strconv"
	"strings"
)

// Under Windows' WDDM driver model nvidia-smi reports [N/A] as every process's memory, so
// the engine's share of each card is read from the system's GPU memory counters instead:
// "\GPU Process Memory(pid_<pid>_luid_<luid>_phys_<n>)\Dedicated Usage" per process and
// "\GPU Adapter Memory(luid_<luid>_phys_<n>)\Dedicated Usage" per adapter, both in bytes.

// gpuCounters is one sample of those counters, keyed by adapter instance ("luid_..._phys_0").
type gpuCounters struct {
	engine  map[string]uint64 // VRAM the engine holds on each adapter
	adapter map[string]uint64 // VRAM every process together holds on each adapter
}

// splitGPUCounterName splits "pid_2544_luid_0x0_0x12947_phys_0" into 2544 and
// "luid_0x0_0x12947_phys_0". An adapter instance has no pid part and returns pid -1.
func splitGPUCounterName(name string) (pid int, adapter string) {
	rest, ok := strings.CutPrefix(name, "pid_")
	if !ok {
		return -1, name
	}
	num, adapter, ok := strings.Cut(rest, "_")
	if !ok {
		return -1, ""
	}
	pid, err := strconv.Atoi(num)
	if err != nil {
		return -1, ""
	}
	return pid, adapter
}

// engineMemFromCounters attributes the engine's VRAM to the cards nvidia-smi listed. The
// counters know adapters only by LUID, so each adapter is matched to the card whose used
// memory is closest to the adapter's total. Adapters that match no card (an integrated GPU,
// a virtual display) are left out.
func engineMemFromCounters(gpus []GPUStat, c gpuCounters) map[string]int {
	adapters := make([]string, 0, len(c.engine))
	for a, bytes := range c.engine {
		if bytes > 0 {
			adapters = append(adapters, a)
		}
	}
	sort.Slice(adapters, func(i, j int) bool { return c.engine[adapters[i]] > c.engine[adapters[j]] })
	perCard := map[string]int{}
	taken := map[int]bool{}
	for _, a := range adapters {
		usedMB := int(c.adapter[a] >> 20)
		best, bestDiff := -1, 0
		for i, g := range gpus {
			diff := usedMB - g.MemUsedMB
			if diff < 0 {
				diff = -diff
			}
			if !taken[i] && (best < 0 || diff < bestDiff) {
				best, bestDiff = i, diff
			}
		}
		// The two readings are taken a moment apart, which matters while a model loads.
		if best < 0 || bestDiff > max(1024, gpus[best].MemTotalMB*15/100) {
			continue
		}
		taken[best] = true
		perCard[gpus[best].UUID] = int(c.engine[a] >> 20)
	}
	return perCard
}
