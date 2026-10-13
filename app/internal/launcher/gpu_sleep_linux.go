//go:build linux

package launcher

import (
	"os"
	"path/filepath"
	"strings"
)

const pciDevices = "/sys/bus/pci/devices"

// nvidiaAsleep reports whether every NVIDIA display device is runtime-suspended (D3).
// Reading sysfs does not wake the card, while nvidia-smi does, so the tray checks this
// first and leaves a sleeping laptop GPU alone.
func nvidiaAsleep() bool {
	return nvidiaAsleepIn(pciDevices)
}

func nvidiaAsleepIn(root string) bool {
	entries, err := os.ReadDir(root)
	if err != nil {
		return false
	}
	found := false
	for _, e := range entries {
		dev := filepath.Join(root, e.Name())
		if readTrim(filepath.Join(dev, "vendor")) != "0x10de" || !strings.HasPrefix(readTrim(filepath.Join(dev, "class")), "0x03") {
			continue
		}
		found = true
		if readTrim(filepath.Join(dev, "power", "runtime_status")) != "suspended" {
			return false
		}
	}
	return found
}

// sleepingGPUNames reads card names from the NVIDIA driver's procfs, which answers
// without waking the card.
func sleepingGPUNames() []string {
	files, _ := filepath.Glob("/proc/driver/nvidia/gpus/*/information")
	var names []string
	for _, f := range files {
		for _, line := range strings.Split(readTrim(f), "\n") {
			if name, ok := strings.CutPrefix(line, "Model:"); ok {
				names = append(names, strings.TrimSpace(name))
			}
		}
	}
	return names
}

func readTrim(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
