package launcher

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"
)

type browserCtxKey struct{}

// deviceName is how the website labels this computer.
func deviceName() string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "This computer"
}

// The public site is static. This narrow bridge lets a paired page talk only
// to the local app instance. The model and text stay on this machine.
func (a *App) registerBridgeRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /bridge/ping", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"app": "asenaizer", "version": a.opts.Version, "port": a.port, "device": deviceName()})
	})
	mux.HandleFunc("POST /bridge/pair", a.handleBridgePair)
	mux.HandleFunc("GET /bridge/device", func(w http.ResponseWriter, r *http.Request) {
		b, _ := r.Context().Value(browserCtxKey{}).(pairedBrowser)
		writeJSON(w, 200, map[string]any{"device": deviceName(), "browser": map[string]any{"id": b.ID, "name": b.Name}})
	})
	mux.HandleFunc("POST /bridge/unpair", func(w http.ResponseWriter, r *http.Request) {
		b, _ := r.Context().Value(browserCtxKey{}).(pairedBrowser)
		a.pairing().remove(b.ID, time.Now())
		writeJSON(w, 200, map[string]any{"forgotten": true})
	})
	mux.HandleFunc("GET /bridge/status", a.handleStatus)
	mux.HandleFunc("GET /bridge/config", a.handleConfig)
	mux.HandleFunc("POST /bridge/setup", a.handleSetup)
	mux.HandleFunc("POST /bridge/model/delete", a.handleModelDelete)
	mux.HandleFunc("POST /bridge/model/stop", a.handleModelStop)
	mux.HandleFunc("POST /bridge/model/unload", a.handleUnload)
	mux.HandleFunc("POST /bridge/completion", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		r.URL.Path = "/api/completion"
		a.countInflight(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			a.prepareRewrite(r.Context()) // counted as in flight, so the model is not unloaded meanwhile
			a.apiProxy().ServeHTTP(w, r)
		})).ServeHTTP(w, r)
	})
}

// bridgeOpen lists the bridge paths that work without a paired key.
var bridgeOpen = map[string]bool{"/bridge/ping": true, "/bridge/pair": true}

// corsWriter writes the bridge's CORS headers last, replacing any that a proxied
// llama-server response added. Browsers reject a response with two
// Access-Control-Allow-Origin headers, which Firefox reports as a NetworkError.
type corsWriter struct {
	http.ResponseWriter
	origin string
	wrote  bool
}

func setBridgeCORS(h http.Header, origin string) {
	for k := range h {
		if strings.HasPrefix(k, "Access-Control-") {
			delete(h, k)
		}
	}
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Vary", "Origin")
	h.Set("Access-Control-Allow-Private-Network", "true")
	h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
	h.Set("Access-Control-Max-Age", "600")
}

func (c *corsWriter) WriteHeader(code int) {
	if !c.wrote {
		c.wrote = true
		setBridgeCORS(c.Header(), c.origin)
	}
	c.ResponseWriter.WriteHeader(code)
}

func (c *corsWriter) Write(b []byte) (int, error) {
	if !c.wrote {
		c.WriteHeader(http.StatusOK)
	}
	return c.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController flush streamed tokens through this writer.
func (c *corsWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

func (a *App) bridgeGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if a.webOrigin == "" || origin != a.webOrigin {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}
		w = &corsWriter{ResponseWriter: w, origin: a.webOrigin}
		setBridgeCORS(w.Header(), a.webOrigin)
		w.Header().Set("Cache-Control", "no-store")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if !bridgeOpen[r.URL.Path] {
			key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			b, ok := a.pairing().authenticate(key, time.Now())
			if !ok {
				writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"code": "pairing_required", "message": "This browser is not paired with the device."}})
				return
			}
			r = r.WithContext(context.WithValue(r.Context(), browserCtxKey{}, b))
			a.noteBridge(time.Now())
		}
		r.Header.Set("X-Humanizer", "1")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		a.touch()
		next.ServeHTTP(w, r)
	})
}

// handleBridgePair turns the code shown in the app into a key for this browser.
func (a *App) handleBridgePair(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]any{"error": map[string]any{"code": "bad_request", "message": "Invalid request."}})
		return
	}
	b, key, err := a.pairing().redeem(req.Code, req.Name, time.Now())
	if err != nil {
		code, status := "pair_failed", http.StatusForbidden
		switch {
		case errors.Is(err, errNoPairCode):
			code = "no_code"
		case errors.Is(err, errPairExpired):
			code = "expired"
		case errors.Is(err, errPairExhausted):
			code = "exhausted"
		case errors.Is(err, errWrongPair):
			code = "wrong_code"
		default:
			status = http.StatusInternalServerError
		}
		writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": err.Error()}})
		return
	}
	a.logf("browser paired: %s", b.Name)
	writeJSON(w, 200, map[string]any{"key": key, "browser": map[string]any{"id": b.ID, "name": b.Name}, "device": deviceName()})
}
