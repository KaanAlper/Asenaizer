package launcher

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// Lazy engine (--lazy-engine, used by the tray): the model is loaded into GPU memory only
// while the Asenaizer website is connected, and unloaded again when the site goes away or
// no rewrite has run for a while. A parked model waits in phaseStopped with its tier selected.

const (
	siteGoneAfter   = 90 * time.Second // the site polls /bridge/status every 3 s while it is open
	engineIdleAfter = 10 * time.Minute // no rewrite for this long frees the GPU even if the site is open
	coldStartWait   = 2 * time.Minute  // a rewrite waits this long for a parked model to load
	lazyTick        = 15 * time.Second
	readyPoll       = 250 * time.Millisecond
)

func (a *App) siteActive(now time.Time) bool {
	last := a.lastBridge.Load()
	return last != 0 && now.Sub(time.Unix(0, last)) < siteGoneAfter
}

// autoStart is used where the app would start the engine on its own at boot.
func (a *App) autoStart(t Tier) {
	if !a.lazyEngine || a.siteActive(time.Now()) {
		a.startEngine(t)
		return
	}
	a.park(t)
}

// park selects t as the model to load later without touching the GPU.
func (a *App) park(t Tier) {
	a.mu.Lock()
	a.tier = t.ID
	a.phase = phaseStopped
	a.errInfo = nil
	a.engInfo = engineInfo{}
	a.mu.Unlock()
}

// noteBridge runs for every authenticated bridge request. The first request after a
// silence longer than siteGoneAfter means the website has (re)connected.
func (a *App) noteBridge(now time.Time) {
	prev := a.lastBridge.Swap(now.UnixNano())
	if !a.lazyEngine || (prev != 0 && now.Sub(time.Unix(0, prev)) < siteGoneAfter) {
		return
	}
	a.lastWork.Store(now.UnixNano())
	if a.warmEngine() {
		a.logf("website connected, loading the model")
	}
}

// warmEngine loads the parked model. It reports whether a model is loaded or loading.
func (a *App) warmEngine() bool {
	a.mu.Lock()
	phase, id, ext := a.phase, a.tier, a.externalOn()
	a.mu.Unlock()
	if ext {
		return false
	}
	switch phase {
	case phaseReady, phaseStarting:
		return true
	case phaseStopped:
	default:
		return false
	}
	t, ok := a.cfg.tier(id)
	if !ok || !fileExists(a.modelPath(t)) {
		return false
	}
	a.startEngine(t)
	return true
}

// waitReady blocks until the engine is ready, the request is cancelled or timeout elapses.
func (a *App) waitReady(ctx context.Context, timeout time.Duration) bool {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(readyPoll)
	defer tick.Stop()
	for {
		a.mu.Lock()
		phase := a.phase
		a.mu.Unlock()
		if phase == phaseReady {
			return true
		}
		if phase != phaseStarting {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-deadline.C:
			return false
		case <-tick.C:
		}
	}
}

// prepareRewrite loads a parked model before a website rewrite is proxied to it.
func (a *App) prepareRewrite(ctx context.Context) {
	if !a.lazyEngine {
		return
	}
	a.lastWork.Store(time.Now().UnixNano())
	if a.warmEngine() {
		a.waitReady(ctx, coldStartWait)
	}
}

func (a *App) lazyLoop(ctx context.Context) {
	if !a.lazyEngine {
		return
	}
	t := time.NewTicker(lazyTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			a.maybeUnload(now)
		}
	}
}

// maybeUnload frees the GPU when the website has gone away or stayed idle.
func (a *App) maybeUnload(now time.Time) {
	if a.inflight.Load() > 0 {
		return
	}
	a.mu.Lock()
	loaded := a.phase == phaseReady || a.phase == phaseStarting
	a.mu.Unlock()
	if !loaded {
		return
	}
	siteGone := !a.siteActive(now)
	idle := now.Sub(time.Unix(0, a.lastWork.Load())) >= engineIdleAfter
	if !siteGone && !idle {
		return
	}
	if siteGone {
		a.unloadEngine("website disconnected")
	} else {
		a.unloadEngine(fmt.Sprintf("no rewrite for %s", engineIdleAfter))
	}
}

// unloadEngine frees GPU memory but keeps the selected model, unlike handleModelStop.
// The next website connect or rewrite loads it again.
func (a *App) unloadEngine(reason string) {
	a.logf("%s, unloading the model", reason)
	a.stopEngine()
	a.mu.Lock()
	if a.phase == phaseReady || a.phase == phaseStarting {
		a.phase = phaseStopped
		a.engInfo = engineInfo{}
	}
	a.mu.Unlock()
}

func (a *App) handleUnload(w http.ResponseWriter, r *http.Request) {
	if a.inflight.Load() > 0 {
		writeJSON(w, 409, map[string]any{"error": "a rewrite is still running"})
		return
	}
	a.unloadEngine("unload requested")
	writeJSON(w, 200, map[string]any{"unloaded": true})
}
