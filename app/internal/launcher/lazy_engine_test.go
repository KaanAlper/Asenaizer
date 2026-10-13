package launcher

import (
	"context"
	"os"
	"testing"
	"time"
)

func lazyApp(t *testing.T) *App {
	t.Helper()
	a := &App{cfg: testConfig(t), dataDir: t.TempDir(), lazyEngine: true}
	a.rootCtx, a.shutdown = context.WithCancel(context.Background())
	t.Cleanup(a.shutdown)
	return a
}

func phaseOf(a *App) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.phase
}

func TestAutoStartParksWhenSiteIsAway(t *testing.T) {
	a := lazyApp(t)
	tier := a.cfg.Tiers[0]
	a.autoStart(tier)
	if got := phaseOf(a); got != phaseStopped {
		t.Fatalf("phase = %q, want %q", got, phaseStopped)
	}
	if a.tier != tier.ID {
		t.Fatalf("tier = %q, want %q", a.tier, tier.ID)
	}
}

func TestSiteActiveWindow(t *testing.T) {
	a := lazyApp(t)
	now := time.Now()
	if a.siteActive(now) {
		t.Fatal("site active before any bridge request")
	}
	a.lastBridge.Store(now.Add(-siteGoneAfter + time.Second).UnixNano())
	if !a.siteActive(now) {
		t.Fatal("site should still be active just inside the window")
	}
	a.lastBridge.Store(now.Add(-siteGoneAfter).UnixNano())
	if a.siteActive(now) {
		t.Fatal("site should be gone after siteGoneAfter")
	}
}

func TestNoteBridgeMarksWorkOnlyOnReconnect(t *testing.T) {
	a := lazyApp(t)
	a.park(a.cfg.Tiers[0]) // model file is missing, so nothing is actually started
	start := time.Now()
	a.noteBridge(start)
	first := a.lastWork.Load()
	if first != start.UnixNano() {
		t.Fatal("first bridge request should count as a connect")
	}
	a.noteBridge(start.Add(3 * time.Second)) // regular status poll
	if a.lastWork.Load() != first {
		t.Fatal("status polling must not reset the idle timer")
	}
	later := start.Add(3*time.Second + siteGoneAfter)
	a.noteBridge(later)
	if a.lastWork.Load() != later.UnixNano() {
		t.Fatal("a request after a long silence is a reconnect")
	}
	if got := phaseOf(a); got != phaseStopped {
		t.Fatalf("missing model file must stay parked, phase = %q", got)
	}
}

func TestMaybeUnload(t *testing.T) {
	now := time.Now()
	tests := []struct {
		name       string
		lastBridge time.Duration
		lastWork   time.Duration
		inflight   int32
		want       string
	}{
		{"site open and recently used", 3 * time.Second, time.Minute, 0, phaseReady},
		{"site closed", siteGoneAfter, time.Minute, 0, phaseStopped},
		{"site open but idle", 3 * time.Second, engineIdleAfter, 0, phaseStopped},
		{"rewrite in flight", siteGoneAfter, engineIdleAfter, 1, phaseReady},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := lazyApp(t)
			a.phase, a.tier = phaseReady, a.cfg.Tiers[0].ID
			a.lastBridge.Store(now.Add(-tt.lastBridge).UnixNano())
			a.lastWork.Store(now.Add(-tt.lastWork).UnixNano())
			a.inflight.Store(tt.inflight)
			a.maybeUnload(now)
			if got := phaseOf(a); got != tt.want {
				t.Fatalf("phase = %q, want %q", got, tt.want)
			}
			if a.tier != a.cfg.Tiers[0].ID {
				t.Fatal("unloading must keep the selected model")
			}
		})
	}
}

func TestWaitReadyStopsOnParkedModel(t *testing.T) {
	a := lazyApp(t)
	a.phase = phaseStopped
	if a.waitReady(context.Background(), time.Second) {
		t.Fatal("a parked model is not ready")
	}
	a.phase = phaseReady
	if !a.waitReady(context.Background(), time.Second) {
		t.Fatal("ready model should return immediately")
	}
}

func TestTraySetupOnlySelectsWhileSiteSetupLoads(t *testing.T) {
	a, base := testLauncher(t)
	a.lazyEngine = true
	a.webOrigin = "https://kaanalper.github.io"
	tier, _ := a.cfg.tier("q6")
	if err := os.MkdirAll(a.modelsDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(a.modelPath(tier), []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _ := postApp(t, base, "/app/setup", `{"tier":"q6"}`); code != 200 {
		t.Fatalf("tray setup: %d", code)
	}
	if got := phaseOf(a); got != phaseStopped {
		t.Fatalf("tray Make default must not load the model, phase = %q", got)
	}
	key := pairTestBrowser(t, a)
	resp, _ := bridgeRequest(t, base, "POST", "/bridge/setup", a.webOrigin, key, `{"tier":"q6"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("site setup: %d", resp.StatusCode)
	}
	if got := phaseOf(a); got == phaseStopped {
		t.Fatal("choosing a model on the website should load it")
	}
}
