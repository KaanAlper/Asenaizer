//go:build !darwin && !windows

package launcher

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// detectInstall: Asenaizer installed by scripts/install-linux.sh (asenaizer-tray and engine/ next
// to the service) updates with the package's own install script. Anything else (a source
// build) only hears that a new version exists.
func detectInstall() installInfo {
	in := installInfo{Kind: "other", Mode: "none", Reason: "unsupported"}
	if runtime.GOOS != "linux" || runtime.GOARCH != "amd64" {
		return in
	}
	exe, err := os.Executable()
	if err != nil {
		return in
	}
	if p, err := filepath.EvalSymlinks(exe); err == nil {
		exe = p
	}
	dir := filepath.Dir(exe)
	if !fileExists(filepath.Join(dir, "asenaizer-tray")) || !dirExists(filepath.Join(dir, "engine")) {
		return in
	}
	in.Kind, in.Path, in.Exe, in.AssetName = "asenaizer", dir, exe, "Asenaizer-{ver}-linux-x64.tar.gz"
	_, bashErr := exec.LookPath("bash")
	_, tarErr := exec.LookPath("tar")
	switch {
	case bashErr != nil || tarErr != nil:
		in.Mode, in.Reason = "manual", "unsupported"
	case !dirWritable(filepath.Dir(dir)):
		in.Mode, in.Reason = "manual", "readonly"
	default:
		in.Mode, in.Reason = "script", ""
	}
	return in
}

// prepareApply unpacks the package, checks it and test-runs the new service; install-linux.sh
// from the package does the rest once this process has exited.
func prepareApply(ctx context.Context, in installInfo, pkg string, args []string, plan *applyPlan, logf func(string, ...any)) error {
	if in.Kind != "asenaizer" || in.Mode != "script" {
		return errors.New("这个平台不支持自动更新")
	}
	staged := stagePathFor(plan)
	_ = os.RemoveAll(staged)
	if err := os.MkdirAll(staged, 0o755); err != nil {
		return err
	}
	logf("解压新版本到 %s", staged)
	// GNU tar refuses absolute names and ../ in members; the package's SHA-256 was checked.
	if out, err := exec.CommandContext(ctx, "tar", "-xzf", pkg, "-C", staged, "--no-same-owner").CombinedOutput(); err != nil {
		_ = os.RemoveAll(staged)
		return fmt.Errorf("could not unpack the update: %v: %s", err, strings.TrimSpace(string(out)))
	}
	if err := checkStaged(staged, plan.To, "Humanizer", "asenaizer-tray", "installer/install-linux.sh"); err != nil {
		_ = os.RemoveAll(staged)
		return err
	}
	if err := checkVersionOutput(ctx, filepath.Join(staged, "Humanizer"), plan.To); err != nil {
		_ = os.RemoveAll(staged)
		return err
	}
	plan.Kind, plan.Staged, plan.Target = "script", staged, in.Path
	plan.Installer = []string{"bash", filepath.Join(staged, "installer", "install-linux.sh"), "--console"}
	// ASZ_KEEP_CHOICES: sign-in start and the desktop shortcut stay as they are. The script opens
	// the tray window again when it is done, where the user started the update.
	plan.InstallerEnv = []string{"ASZ_SOURCE=" + staged, "ASZ_DEFAULTS=1", "ASZ_NO_GUI=1", "ASZ_KEEP_CHOICES=1"}
	plan.Relaunch = []string{filepath.Join(in.Path, "asenaizer-tray")}
	plan.WaitPID = os.Getpid()
	return nil
}

// executePlan: the install script stops every process in the install folder, this one too, so a
// copy of this program in the data folder waits for it and reports the result.
func executePlan(plan *applyPlan, logf func(string, ...any)) {
	if plan.Kind == "script" {
		err := spawnApplyHelper(plan, logf)
		if err == nil {
			return
		}
		logf("%v", err)
	}
	runApplyPlan(plan, defaultApplyHooks(logf))
}

func openPackageFile(p string) error { return openURL(filepath.Dir(p)) }
