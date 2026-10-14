//go:build !windows

package launcher

import (
	"os"
	"strconv"
	"strings"
)

// nvidia-smi reports per-process memory outside Windows, so there is nothing to read here.
func readGPUCounters(pid int) (gpuCounters, bool) { return gpuCounters{}, false }

// processRSSMB reads resident memory from /proc; it returns 0 where /proc does not exist.
func processRSSMB(pid int) int {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		if f := strings.Fields(line); len(f) >= 2 && f[0] == "VmRSS:" {
			return atoiOr0(f[1]) / 1024
		}
	}
	return 0
}
