package launcher

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func bridgeRequest(t *testing.T, base, method, path, origin, key, body string) (*http.Response, map[string]any) {
	t.Helper()
	req, err := http.NewRequest(method, base+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var result map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&result)
	return resp, result
}

// pairTestBrowser pairs a browser the way the website does and returns its key.
func pairTestBrowser(t *testing.T, a *App) string {
	t.Helper()
	code := a.pairing().startCode(time.Now()).code
	_, key, err := a.pairing().redeem(code, "Test browser", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func TestBridgeOriginAndPairing(t *testing.T) {
	a, base := testLauncher(t)
	a.webOrigin = "https://kaanalper.github.io"
	key := pairTestBrowser(t, a)

	resp, _ := bridgeRequest(t, base, "GET", "/bridge/ping", "https://evil.example", "", "")
	if resp.StatusCode != 403 || resp.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("untrusted origin should be refused without CORS")
	}
	resp, _ = bridgeRequest(t, base, "OPTIONS", "/bridge/status", a.webOrigin, "", "")
	if resp.StatusCode != 204 || resp.Header.Get("Access-Control-Allow-Origin") != a.webOrigin {
		t.Fatalf("preflight: %d %v", resp.StatusCode, resp.Header)
	}
	resp, _ = bridgeRequest(t, base, "GET", "/bridge/status", a.webOrigin, "", "")
	if resp.StatusCode != 401 {
		t.Fatal("unpaired site must not read status")
	}
	resp, result := bridgeRequest(t, base, "GET", "/bridge/status", a.webOrigin, key, "")
	if resp.StatusCode != 200 || result["app"] != "humanizer" {
		t.Fatalf("paired status: %d %v", resp.StatusCode, result)
	}
	resp, _ = bridgeRequest(t, base, "POST", "/app/setup", a.webOrigin, key, `{}`)
	if resp.StatusCode != 403 {
		t.Fatal("bridge token must not grant access to old app endpoints")
	}
}

func TestDeleteOnlyInactiveConfiguredModel(t *testing.T) {
	a, base := testLauncher(t)
	a.webOrigin = "https://kaanalper.github.io"
	key := pairTestBrowser(t, a)
	tier, _ := a.cfg.tier("q6")
	path := a.modelPath(tier)
	if err := os.MkdirAll(a.modelsDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	a.tier, a.phase = "q6", phaseReady
	resp, _ := bridgeRequest(t, base, "POST", "/bridge/model/delete", a.webOrigin, key, `{"tier":"q6"}`)
	if resp.StatusCode != 409 || !fileExists(path) {
		t.Fatal("active model should not be deleted")
	}
	resp, _ = bridgeRequest(t, base, "POST", "/bridge/model/stop", a.webOrigin, key, `{}`)
	if resp.StatusCode != 200 || a.phase != phaseSetup || a.tier != "" {
		t.Fatal("active model should stop before deletion")
	}
	resp, result := bridgeRequest(t, base, "POST", "/bridge/model/delete", a.webOrigin, key, `{"tier":"q6"}`)
	if resp.StatusCode != 200 || result["deleted"] != "q6" || fileExists(path) {
		t.Fatalf("inactive deletion: %d %v", resp.StatusCode, result)
	}
}

// A proxied llama-server response carries its own CORS headers. The bridge must
// send exactly one Access-Control-Allow-Origin or the browser drops the response.
func TestBridgeReplacesUpstreamCORSAndKeepsStreaming(t *testing.T) {
	a := &App{cfg: testConfig(t), dataDir: t.TempDir(), webOrigin: "https://kaanalper.github.io"}
	key := pairTestBrowser(t, a)
	var flushed atomic.Bool
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Access-Control-Allow-Origin", "")
		w.Header().Add("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("data: {}\n\n"))
		flushed.Store(http.NewResponseController(w).Flush() == nil)
	})
	srv := httptest.NewServer(a.bridgeGuard(upstream))
	defer srv.Close()
	resp, _ := bridgeRequest(t, srv.URL, "POST", "/bridge/completion", a.webOrigin, key, `{}`)
	if got := resp.Header.Values("Access-Control-Allow-Origin"); len(got) != 1 || got[0] != a.webOrigin {
		t.Fatalf("Access-Control-Allow-Origin = %q, want exactly [%q]", got, a.webOrigin)
	}
	if resp.Header.Get("Access-Control-Allow-Credentials") != "" {
		t.Fatal("upstream CORS headers must not leak through")
	}
	if !flushed.Load() {
		t.Fatal("streamed tokens must still be flushable through the bridge")
	}
}

func TestTrayDisconnectPausesBrowserUntilReconnect(t *testing.T) {
	a, base := testLauncher(t)
	a.webOrigin = "https://kaanalper.github.io"
	key := pairTestBrowser(t, a)
	if code, _ := postApp(t, base, "/app/pairings/disconnect", `{}`); code != 200 {
		t.Fatalf("disconnect: %d", code)
	}
	resp, result := bridgeRequest(t, base, "GET", "/bridge/status", a.webOrigin, key, "")
	errInfo, _ := result["error"].(map[string]any)
	if resp.StatusCode != 403 || errInfo["code"] != "disconnected" {
		t.Fatalf("paused browser: %d %v", resp.StatusCode, result)
	}
	if list := a.pairing().list(); len(list) != 1 {
		t.Fatal("disconnect must keep the pairing")
	}
	resp, _ = bridgeRequest(t, base, "POST", "/bridge/resume", a.webOrigin, key, `{}`)
	if resp.StatusCode != 200 {
		t.Fatalf("resume: %d", resp.StatusCode)
	}
	resp, _ = bridgeRequest(t, base, "GET", "/bridge/status", a.webOrigin, key, "")
	if resp.StatusCode != 200 {
		t.Fatalf("after reconnect: %d", resp.StatusCode)
	}
}
