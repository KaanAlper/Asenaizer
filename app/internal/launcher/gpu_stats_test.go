package launcher

import (
	"reflect"
	"testing"
)

func TestParseGPUQuery(t *testing.T) {
	tests := []struct {
		name string
		out  string
		want []GPUStat
	}{
		{"single laptop gpu", "GPU-a1, NVIDIA GeForce RTX 5080 Laptop GPU, 10342, 16303, 54, 3\n",
			[]GPUStat{{UUID: "GPU-a1", Name: "NVIDIA GeForce RTX 5080 Laptop GPU", MemUsedMB: 10342, MemTotalMB: 16303, TempC: 54, UtilPct: 3}}},
		{"comma in name", "GPU-t4, Tesla, T4, 100, 15360, 40, 0",
			[]GPUStat{{UUID: "GPU-t4", Name: "Tesla, T4", MemUsedMB: 100, MemTotalMB: 15360, TempC: 40, UtilPct: 0}}},
		{"not available fields become zero", "GPU-x, GPU, [N/A], 8192, [N/A], [N/A]",
			[]GPUStat{{UUID: "GPU-x", Name: "GPU", MemTotalMB: 8192}}},
		{"two gpus", "GPU-a, A, 1, 2, 3, 4\nGPU-b, B, 5, 6, 7, 8",
			[]GPUStat{{UUID: "GPU-a", Name: "A", MemUsedMB: 1, MemTotalMB: 2, TempC: 3, UtilPct: 4}, {UUID: "GPU-b", Name: "B", MemUsedMB: 5, MemTotalMB: 6, TempC: 7, UtilPct: 8}}},
		{"empty", "", nil},
		{"short line skipped", "0, A, 1", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseGPUQuery(tt.out); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("parseGPUQuery() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestParseEngineMem(t *testing.T) {
	out := "GPU-aaa, 1472, 4\nGPU-aaa, 490083, 6120\nGPU-bbb, 490083, 4000\n"
	tests := []struct {
		pid  int
		want map[string]int
	}{
		{490083, map[string]int{"GPU-aaa": 6120, "GPU-bbb": 4000}}, // model split across two cards
		{1472, map[string]int{"GPU-aaa": 4}},
		{999, map[string]int{}},
	}
	for _, tt := range tests {
		if got := parseEngineMem(out, tt.pid); !reflect.DeepEqual(got, tt.want) {
			t.Errorf("parseEngineMem(pid %d) = %v, want %v", tt.pid, got, tt.want)
		}
	}
}

func TestSplitGPUCounterName(t *testing.T) {
	tests := []struct {
		name, adapter string
		pid           int
	}{
		{"pid_2544_luid_0x00000000_0x00012947_phys_0", "luid_0x00000000_0x00012947_phys_0", 2544},
		{"luid_0x00000000_0x00012947_phys_0", "luid_0x00000000_0x00012947_phys_0", -1},
		{"pid_x_luid_0x0_0x1_phys_0", "", -1},
		{"pid_12", "", -1},
	}
	for _, tt := range tests {
		if pid, adapter := splitGPUCounterName(tt.name); pid != tt.pid || adapter != tt.adapter {
			t.Errorf("splitGPUCounterName(%q) = %d, %q, want %d, %q", tt.name, pid, adapter, tt.pid, tt.adapter)
		}
	}
}

func TestEngineMemFromCounters(t *testing.T) {
	const mb = 1 << 20
	one := []GPUStat{{UUID: "GPU-a", MemUsedMB: 12400, MemTotalMB: 16376}}
	two := []GPUStat{{UUID: "GPU-a", MemUsedMB: 6500, MemTotalMB: 16376}, {UUID: "GPU-b", MemUsedMB: 4200, MemTotalMB: 8192}}
	tests := []struct {
		name string
		gpus []GPUStat
		c    gpuCounters
		want map[string]int
	}{
		{"one card next to a virtual display", one, gpuCounters{
			engine:  map[string]uint64{"luid_n": 9900 * mb},
			adapter: map[string]uint64{"luid_n": 12450 * mb, "luid_v": 0},
		}, map[string]int{"GPU-a": 9900}},
		{"model split across two cards", two, gpuCounters{
			engine:  map[string]uint64{"luid_1": 6000 * mb, "luid_2": 4000 * mb},
			adapter: map[string]uint64{"luid_1": 6510 * mb, "luid_2": 4190 * mb},
		}, map[string]int{"GPU-a": 6000, "GPU-b": 4000}},
		{"memory on an integrated GPU is not shown on the card", one, gpuCounters{
			engine:  map[string]uint64{"luid_igpu": 300 * mb},
			adapter: map[string]uint64{"luid_igpu": 900 * mb, "luid_n": 12400 * mb},
		}, map[string]int{}},
		{"engine not on any GPU", one, gpuCounters{engine: map[string]uint64{}, adapter: map[string]uint64{"luid_n": 2400 * mb}}, map[string]int{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := engineMemFromCounters(tt.gpus, tt.c); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("engineMemFromCounters() = %v, want %v", got, tt.want)
			}
		})
	}
}
