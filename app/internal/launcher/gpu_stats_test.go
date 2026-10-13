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
