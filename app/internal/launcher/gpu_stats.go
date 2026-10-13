package launcher

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// GPUStat is the live state of one graphics card, shown in the tray window.
type GPUStat struct {
	UUID        string `json:"uuid"`
	Name        string `json:"name"`
	MemUsedMB   int    `json:"mem_used_mb"`
	MemTotalMB  int    `json:"mem_total_mb"`
	TempC       int    `json:"temp_c"`
	UtilPct     int    `json:"util_pct"`
	EngineMemMB int    `json:"engine_mem_mb"`    // VRAM held by this app's llama-server on this card
	Asleep      bool   `json:"asleep,omitempty"` // powered down; only the name from the last query is known
}

type gpuResp struct {
	GPUs        []GPUStat `json:"gpus"`
	EngineRAMMB int       `json:"engine_ram_mb,omitempty"`
	Error       string    `json:"error,omitempty"`
}

const gpuStatsTTL = 2 * time.Second

// gpuCache keeps every poll from spawning nvidia-smi.
type gpuCache struct {
	mu   sync.Mutex
	at   time.Time
	resp gpuResp
}

var gpuStatsCache gpuCache

// lastGPUNames remembers card names so a sleeping card can still be labelled.
var lastGPUNames []string

func (a *App) handleGPU(w http.ResponseWriter, r *http.Request) {
	pid := 0
	a.mu.Lock()
	if a.engine != nil && a.engine.cmd != nil && a.engine.cmd.Process != nil {
		pid = a.engine.cmd.Process.Pid
	}
	a.mu.Unlock()

	gpuStatsCache.mu.Lock()
	defer gpuStatsCache.mu.Unlock()
	if time.Since(gpuStatsCache.at) > gpuStatsTTL {
		if pid == 0 && nvidiaAsleep() {
			gpuStatsCache.resp = sleepingGPUs()
		} else {
			gpuStatsCache.resp = readGPUStats(r.Context(), pid)
			lastGPUNames = lastGPUNames[:0]
			for _, g := range gpuStatsCache.resp.GPUs {
				lastGPUNames = append(lastGPUNames, g.Name)
			}
		}
		gpuStatsCache.at = time.Now()
	}
	writeJSON(w, http.StatusOK, gpuStatsCache.resp)
}

// sleepingGPUs describes powered-down cards without running nvidia-smi, which would wake them.
func sleepingGPUs() gpuResp {
	names := lastGPUNames
	if len(names) == 0 {
		names = sleepingGPUNames()
	}
	if len(names) == 0 {
		names = []string{"NVIDIA GPU"}
	}
	resp := gpuResp{}
	for _, n := range names {
		resp.GPUs = append(resp.GPUs, GPUStat{Name: n, Asleep: true})
	}
	return resp
}

func readGPUStats(ctx context.Context, enginePID int) gpuResp {
	var resp gpuResp
	if enginePID > 0 {
		resp.EngineRAMMB = processRSSMB(enginePID)
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := runSMI(ctx, "--query-gpu=uuid,name,memory.used,memory.total,temperature.gpu,utilization.gpu")
	if err != nil {
		resp.Error = "nvidia-smi unavailable"
		return resp
	}
	resp.GPUs = parseGPUQuery(string(out))
	if enginePID > 0 && len(resp.GPUs) > 0 {
		apps, err := runSMI(ctx, "--query-compute-apps=gpu_uuid,pid,used_memory")
		if err == nil {
			// llama.cpp splits layers across every visible card, so the share is counted per card.
			perCard := parseEngineMem(string(apps), enginePID)
			for i := range resp.GPUs {
				resp.GPUs[i].EngineMemMB = perCard[resp.GPUs[i].UUID]
			}
		}
	}
	return resp
}

// runSMI runs an nvidia-smi CSV query without flashing a console window on Windows.
func runSMI(ctx context.Context, query string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "nvidia-smi", query, "--format=csv,noheader,nounits")
	prepareCmd(cmd)
	return cmd.Output()
}

// parseGPUQuery parses uuid,name,memory.used,memory.total,temperature.gpu,utilization.gpu.
func parseGPUQuery(out string) []GPUStat {
	var gpus []GPUStat
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, ",")
		if len(f) < 6 {
			continue
		}
		for i := range f {
			f[i] = strings.TrimSpace(f[i])
		}
		n := len(f) // card names may contain commas, so numbers are read from the end
		gpus = append(gpus, GPUStat{
			UUID: f[0], Name: strings.Join(f[1:n-4], ", "), MemUsedMB: atoiOr0(f[n-4]), MemTotalMB: atoiOr0(f[n-3]),
			TempC: atoiOr0(f[n-2]), UtilPct: atoiOr0(f[n-1]),
		})
	}
	return gpus
}

// parseEngineMem returns the VRAM (MB) a process holds on each card, keyed by GPU UUID,
// from gpu_uuid,pid,used_memory rows.
func parseEngineMem(out string, pid int) map[string]int {
	perCard := map[string]int{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, ",")
		if len(f) < 3 || atoiOr0(strings.TrimSpace(f[1])) != pid {
			continue
		}
		perCard[strings.TrimSpace(f[0])] += atoiOr0(strings.TrimSpace(f[2]))
	}
	return perCard
}

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

func atoiOr0(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}
