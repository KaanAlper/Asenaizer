//go:build !linux

package launcher

// nvidiaAsleep is only detectable through sysfs; elsewhere the card is always queried.
func nvidiaAsleep() bool { return false }

func sleepingGPUNames() []string { return nil }
