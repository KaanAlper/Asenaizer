package launcher

import (
	"encoding/json"
	"net/http"
	"os"
)

// Stop inference before deleting the currently selected model. In-flight
// rewrites must finish or be cancelled by the user first.
func (a *App) handleModelStop(w http.ResponseWriter, r *http.Request) {
	if a.inflight.Load() > 0 {
		writeJSON(w, 409, map[string]any{"error": "a rewrite is still running"})
		return
	}
	a.mu.Lock()
	phase := a.phase
	a.mu.Unlock()
	if phase == phaseDownloading {
		writeJSON(w, 409, map[string]any{"error": "pause the download first"})
		return
	}
	a.stopEngine()
	a.mu.Lock()
	a.phase = phaseSetup
	a.tier = ""
	a.engInfo = engineInfo{}
	a.mu.Unlock()
	writeJSON(w, 200, map[string]any{"stopped": true})
}

// Delete only a configured model file, never a user-supplied path. The active
// model must be switched or the app stopped first.
func (a *App) handleModelDelete(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Tier string `json:"tier"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]any{"error": "bad json"})
		return
	}
	tier, ok := a.cfg.tier(req.Tier)
	if !ok {
		writeJSON(w, 400, map[string]any{"error": "unknown tier"})
		return
	}
	a.mu.Lock()
	busy := a.tier == req.Tier && (a.phase == phaseReady || a.phase == phaseStarting || a.phase == phaseDownloading)
	a.mu.Unlock()
	if busy {
		writeJSON(w, 409, map[string]any{"error": "model is active; select another tier or close the app first"})
		return
	}
	path := a.modelPath(tier)
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			writeJSON(w, 404, map[string]any{"error": "model not downloaded"})
		} else {
			writeJSON(w, 500, map[string]any{"error": "could not delete model"})
		}
		return
	}
	writeJSON(w, 200, map[string]any{"deleted": req.Tier})
}
