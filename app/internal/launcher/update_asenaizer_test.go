package launcher

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAssetForAsenaizerPackages(t *testing.T) {
	rel := &appRelease{Version: "0.2.0", Assets: []releaseAsset{
		{Name: "Asenaizer-0.2.0-linux-x64.tar.gz"}, {Name: "Asenaizer-0.2.0-linux-x64.tar.gz.sha256"},
		{Name: "Asenaizer-windows-x64-0.2.0.zip"}, {Name: "Asenaizer-windows-x64-0.2.0.zip.sha256"},
		{Name: "Humanizer-0.2.0-windows-x64-setup.exe"},
	}}
	win := installInfo{AssetName: "Asenaizer-windows-x64-{ver}.zip"}
	linux := installInfo{AssetName: "Asenaizer-{ver}-linux-x64.tar.gz"}
	if a := assetFor(rel, win); a == nil || a.Name != "Asenaizer-windows-x64-0.2.0.zip" {
		t.Fatalf("Windows package: %+v", a)
	}
	if a := assetFor(rel, linux); a == nil || a.Name != "Asenaizer-0.2.0-linux-x64.tar.gz" {
		t.Fatalf("Linux package: %+v", a)
	}
	if a := assetFor(rel, installInfo{Suffix: "-windows-x64-setup.exe"}); a == nil || a.Name != "Humanizer-0.2.0-windows-x64-setup.exe" {
		t.Fatalf("the upstream suffix rule still applies: %+v", a)
	}
	if assetFor(&appRelease{Version: "0.3.0", Assets: rel.Assets}, win) != nil || assetFor(nil, win) != nil {
		t.Fatal("a package of another version must not be picked")
	}
}

func TestVersionInAsenaizerPackageNames(t *testing.T) {
	for name, want := range map[string]string{
		"Asenaizer-windows-x64-0.2.0.zip":  "0.2.0",
		"Asenaizer-0.2.0-linux-x64.tar.gz": "0.2.0",
		"Asenaizer-0.2.0-stage":            "0.2.0",
		"Asenaizer-Setup-x64.exe":          "",
		"apply-plan.json":                  "",
	} {
		if got := versionInPackageName(name); got != want {
			t.Errorf("versionInPackageName(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestPackageVerifierTarGz(t *testing.T) {
	dir := t.TempDir()
	good, bad := filepath.Join(dir, "good.tar.gz"), filepath.Join(dir, "bad.tar.gz")
	os.WriteFile(good, []byte{0x1f, 0x8b, 8, 0}, 0o644)
	os.WriteFile(bad, []byte("<html>portal</html>"), 0o644)
	if err := packageVerifier("Asenaizer-0.2.0-linux-x64.tar.gz")(good); err != nil {
		t.Fatalf("gzip data rejected: %v", err)
	}
	if err := packageVerifier("Asenaizer-0.2.0-linux-x64.tar.gz")(bad); err == nil {
		t.Fatal("a web page must not pass as a package")
	}
}

func TestCheckStaged(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "installer"), 0o755)
	os.WriteFile(filepath.Join(dir, "VERSION"), []byte("0.2.0\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "installer", "setup.ps1"), []byte("x"), 0o644)
	if err := checkStaged(dir, "0.2.0", "installer/setup.ps1"); err != nil {
		t.Fatal(err)
	}
	if err := checkStaged(dir, "0.2.1", "installer/setup.ps1"); err == nil {
		t.Fatal("a package of another version must be refused")
	}
	if err := checkStaged(dir, "0.2.0", "app/Humanizer.exe"); err == nil || !strings.Contains(err.Error(), "app/Humanizer.exe") {
		t.Fatalf("a missing file must be named: %v", err)
	}
}

func TestApplyScriptPlan(t *testing.T) {
	tests := []struct {
		name      string
		scriptErr error
		up        []string // versions that answer without a relaunch
		upAfter   []string // versions that answer after the tray is started again
		ok        bool
		relaunch  bool
	}{
		{"installed and the script restarted the tray", nil, []string{"0.2.0"}, nil, true, false},
		{"installed, the tray was not running", nil, nil, []string{"0.2.0"}, true, true},
		{"the script failed and put the old version back", errors.New("exit status 1"), []string{"0.1.0"}, nil, false, false},
		{"installed but the new version never answers", nil, nil, nil, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			staged := filepath.Join(dir, "updates", "Asenaizer-0.2.0-stage")
			os.MkdirAll(staged, 0o755)
			var gotArgv, gotEnv []string
			relaunched := false
			up := map[string]bool{}
			for _, v := range tt.up {
				up[v] = true
			}
			h := applyHooks{
				logf: t.Logf,
				install: func(argv, env []string, _ time.Duration) error {
					gotArgv, gotEnv = argv, env
					return tt.scriptErr
				},
				launch: func(argv, env []string) error {
					relaunched = true
					for _, v := range tt.upAfter {
						up[v] = true
					}
					return nil
				},
				ready:   func(_, v string, _ time.Duration) bool { return up[v] },
				waitPID: func(int, time.Duration) {},
				kill:    func(string) {},
			}
			plan := &applyPlan{Kind: "script", From: "0.1.0", To: "0.2.0", DataDir: dir, Staged: staged,
				Installer: []string{"bash", "install-linux.sh", "--console"}, InstallerEnv: []string{"ASZ_KEEP_CHOICES=1"},
				Relaunch: []string{"asenaizer-tray"}, ReadySec: 1}
			res := runApplyPlan(plan, h)
			if res.OK != tt.ok || relaunched != tt.relaunch {
				t.Fatalf("ok=%v relaunched=%v, want ok=%v relaunched=%v (%+v)", res.OK, relaunched, tt.ok, tt.relaunch, res)
			}
			if strings.Join(gotArgv, " ") != "bash install-linux.sh --console" || strings.Join(gotEnv, " ") != "ASZ_KEEP_CHOICES=1" {
				t.Fatalf("installer called with %v %v", gotArgv, gotEnv)
			}
			if _, err := os.Stat(staged); err == nil {
				t.Fatal("the unpacked package must be removed")
			}
			if r := readResult(t, dir); r.OK != tt.ok || r.From != "0.1.0" || r.To != "0.2.0" {
				t.Fatalf("update-result.json: %+v", r)
			}
		})
	}
}
