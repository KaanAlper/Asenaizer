//go:build linux

package launcher

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNvidiaAsleepIn(t *testing.T) {
	dev := func(root, name, vendor, class, status string) {
		dir := filepath.Join(root, name, "power")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		_ = os.WriteFile(filepath.Join(root, name, "vendor"), []byte(vendor+"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(root, name, "class"), []byte(class+"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(dir, "runtime_status"), []byte(status+"\n"), 0o644)
	}
	tests := []struct {
		name  string
		setup func(root string)
		want  bool
	}{
		{"no nvidia card", func(r string) { dev(r, "00:02.0", "0x8086", "0x030000", "active") }, false},
		{"sleeping card", func(r string) { dev(r, "01:00.0", "0x10de", "0x030000", "suspended") }, true},
		{"awake card", func(r string) { dev(r, "01:00.0", "0x10de", "0x030000", "active") }, false},
		{"audio function ignored", func(r string) {
			dev(r, "01:00.0", "0x10de", "0x030000", "suspended")
			dev(r, "01:00.1", "0x10de", "0x040300", "active")
		}, true},
		{"one of two cards awake", func(r string) {
			dev(r, "01:00.0", "0x10de", "0x030000", "suspended")
			dev(r, "02:00.0", "0x10de", "0x030200", "active")
		}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			tt.setup(root)
			if got := nvidiaAsleepIn(root); got != tt.want {
				t.Fatalf("nvidiaAsleepIn = %v, want %v", got, tt.want)
			}
		})
	}
}
