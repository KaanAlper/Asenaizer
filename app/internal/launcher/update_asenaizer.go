package launcher

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Asenaizer updates itself with its own installer. The service downloads the release package
// (Asenaizer-windows-x64-<ver>.zip, Asenaizer-<ver>-linux-x64.tar.gz), checks its SHA-256,
// unpacks it and test-runs the new service. It then exits, and a copy of itself in the data
// folder runs the package's installer script (installer/setup.ps1, installer/install-linux.sh)
// with the user's current choices. The script stops the tray, replaces the files, puts
// everything back if a step fails and starts the tray again; the copy only waits for the new
// version to answer and writes update-result.json, which the tray shows.

// assetFor picks this install's package from a release: the exact Asenaizer name, or the
// upstream Humanizer suffix rule.
func assetFor(rel *appRelease, in installInfo) *releaseAsset {
	if rel == nil {
		return nil
	}
	if in.AssetName == "" {
		return pickAsset(rel.Assets, in.Suffix)
	}
	want := strings.ReplaceAll(in.AssetName, "{ver}", rel.Version)
	for i, a := range rel.Assets {
		if a.Name == want {
			return &rel.Assets[i]
		}
	}
	return nil
}

// stagePathFor is where a package is unpacked before its installer runs. The name carries the
// version, so cleanupStale removes it once that version is installed.
func stagePathFor(plan *applyPlan) string {
	return filepath.Join(plan.DataDir, "updates", "Asenaizer-"+plan.To+"-stage")
}

// checkStaged makes sure an unpacked package has the files the installer needs and the
// version it was released as.
func checkStaged(staged, version string, files ...string) error {
	for _, f := range append([]string{"VERSION"}, files...) {
		if !fileExists(filepath.Join(staged, filepath.FromSlash(f))) {
			return fmt.Errorf("the update package is incomplete: %s is missing", f)
		}
	}
	b, _ := os.ReadFile(filepath.Join(staged, "VERSION"))
	if got := strings.TrimSpace(string(b)); got != version {
		return fmt.Errorf("the update package is version %q, expected %s", got, version)
	}
	return nil
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// runScriptPlan runs the new package's installer script and reports how it went. The script
// does the stopping, replacing, rolling back and restarting itself.
func runScriptPlan(p *applyPlan, h applyHooks, res updateResult, readyTimeout time.Duration) updateResult {
	fail := func(format string, args ...any) updateResult {
		res.OK, res.Error = false, fmt.Sprintf(format, args...)
		h.logf("update failed: %s", res.Error)
		writeResult(p.DataDir, res)
		return res
	}
	install := h.install
	if install == nil {
		install = func(argv, env []string, timeout time.Duration) error { return runInstaller(argv, timeout, env...) }
	}
	h.logf("running the installer: %s", strings.Join(p.Installer, " "))
	err := install(p.Installer, p.InstallerEnv, 20*time.Minute)
	_ = os.RemoveAll(p.Staged)
	want := p.To
	if err != nil {
		want = p.From // the script has put the previous version back
	}
	up := h.ready(p.DataDir, want, readyTimeout)
	if !up && len(p.Relaunch) > 0 { // the script restarts the tray only if it was running
		if lerr := h.launch(p.Relaunch, nil); lerr == nil {
			up = h.ready(p.DataDir, want, readyTimeout)
		}
	}
	if err != nil {
		return fail("The update could not be installed, so Asenaizer %s is still in use: %v", p.From, err)
	}
	if !up {
		return fail("Asenaizer %s was installed but did not start within %s.", p.To, readyTimeout)
	}
	res.OK = true
	writeResult(p.DataDir, res)
	h.logf("updated to %s", p.To)
	return res
}

// spawnApplyHelper copies this program into the data folder and starts the copy with the plan.
// The installers stop every Asenaizer process in the install folder, which includes this one.
func spawnApplyHelper(plan *applyPlan, logf func(string, ...any)) error {
	dir := filepath.Join(plan.DataDir, "updates")
	_ = os.MkdirAll(dir, 0o755)
	planPath := filepath.Join(dir, "apply-plan.json")
	b, _ := json.MarshalIndent(plan, "", "  ")
	if err := writeFileAtomic(planPath, b); err != nil {
		return fmt.Errorf("写更新计划失败:%w", err)
	}
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("找不到自己的路径:%w", err)
	}
	name := "humanizer-updater-" + strconv.Itoa(os.Getpid())
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	helper := filepath.Join(dir, name)
	if err := copyFile(exe, helper); err != nil {
		return fmt.Errorf("复制更新助手失败:%w", err)
	}
	_ = os.Chmod(helper, 0o755)
	cmd := exec.Command(helper, "--apply-update", planPath)
	cmd.Dir = dir
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动更新助手失败:%w", err)
	}
	_ = cmd.Process.Release()
	logf("更新助手已启动(pid %d),本进程退出", cmd.Process.Pid)
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
