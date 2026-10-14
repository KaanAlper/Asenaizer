package launcher

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestLANHostOK(t *testing.T) {
	tests := []struct {
		host string
		want bool
	}{
		{"192.168.1.23:47630", true},
		{"10.0.0.5", true},
		{"[fe80::1]:47630", true},
		{"Desk-PC:47630", true},
		{"desk-pc.local:47630", true},
		{"desk-pc.local.:47630", true},
		{"evil.example:47630", false},
		{"desk-pc.evil.example:47630", false},
		{"", false},
	}
	for _, tt := range tests {
		if got := lanHostOK(tt.host, "DESK-PC"); got != tt.want {
			t.Errorf("lanHostOK(%q) = %v, want %v", tt.host, got, tt.want)
		}
	}
}

// testLANServer serves a's network handler with a website folder holding index.html.
func testLANServer(t *testing.T) (*App, string) {
	t.Helper()
	a, _ := testLauncher(t)
	a.siteDir = t.TempDir()
	for _, f := range siteFiles {
		if err := os.WriteFile(filepath.Join(a.siteDir, f), []byte("file "+f), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	srv := httptest.NewServer(a.lanHandler())
	t.Cleanup(srv.Close)
	return a, srv.URL
}

func lanGet(t *testing.T, base, path string, edit func(*http.Request)) (int, string) {
	t.Helper()
	req, err := http.NewRequest("GET", base+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if edit != nil {
		edit(req)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestLANServesOnlyTheWebsiteAndThePairedBridge(t *testing.T) {
	a, base := testLANServer(t)

	if code, body := lanGet(t, base, "/", nil); code != 200 || body != "file index.html" {
		t.Fatalf("GET / = %d %q", code, body)
	}
	if code, _ := lanGet(t, base, "/app.js", nil); code != 200 {
		t.Fatalf("GET /app.js = %d", code)
	}
	// The device's own pages and the unauthenticated local API never reach the network.
	for _, path := range []string{"/app/status", "/app/config", "/api/completion", "/tray.html", "/index.html/../tray.html", "/README.md"} {
		if code, _ := lanGet(t, base, path, nil); code == 200 {
			t.Errorf("GET %s must not be served on the network", path)
		}
	}
	if code, _ := lanGet(t, base, "/", func(r *http.Request) { r.Host = "evil.example:47630" }); code != 403 {
		t.Errorf("a foreign host name (DNS rebinding) must be refused, got %d", code)
	}
	if code, _ := lanGet(t, base, "/bridge/ping", func(r *http.Request) { r.Header.Set("Origin", "https://evil.example") }); code != 403 {
		t.Errorf("another site's origin must be refused, got %d", code)
	}
	if code, _ := lanGet(t, base, "/bridge/device", nil); code != 401 {
		t.Errorf("an unpaired browser must not use the bridge, got %d", code)
	}

	// Pairing from the page this device serves: a same-origin POST carries its own origin.
	pairCode := a.pairing().startCode(time.Now()).code
	req, _ := http.NewRequest("POST", base+"/bridge/pair", strings.NewReader(`{"code":"`+pairCode+`","name":"Firefox on Windows"}`))
	req.Header.Set("Origin", base)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var paired struct {
		Key string `json:"key"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&paired)
	resp.Body.Close()
	if resp.StatusCode != 200 || paired.Key == "" {
		t.Fatalf("pair: %d %+v", resp.StatusCode, paired)
	}
	code, body := lanGet(t, base, "/bridge/device", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+paired.Key) })
	if code != 200 || !strings.Contains(body, "Firefox on Windows") {
		t.Fatalf("paired device: %d %s", code, body)
	}
	if code, _ := lanGet(t, base, "/bridge/status", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+paired.Key) }); code != 200 {
		t.Fatalf("paired status: %d", code)
	}
}

func TestLANStartStopAndSetting(t *testing.T) {
	lanListenHost = "127.0.0.1"
	t.Cleanup(func() { lanListenHost = "" })
	a, base := testLauncher(t)
	a.siteDir = t.TempDir()
	if code, out := postApp(t, base, "/app/lan", `{"enabled":true}`); code != 200 || out["enabled"] != false || out["error"] == "" {
		t.Fatalf("without website files: %d %v", code, out)
	}
	if err := os.WriteFile(filepath.Join(a.siteDir, "index.html"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out := postApp(t, base, "/app/lan", `{"enabled":true}`)
	if code != 200 || out["enabled"] != true {
		t.Fatalf("enable: %d %v", code, out)
	}
	t.Cleanup(a.stopLAN)
	port := int(out["port"].(float64))
	if port < lanPortBase || port >= lanPortBase+lanPortSpan {
		t.Fatalf("port %d outside %d..%d", port, lanPortBase, lanPortBase+lanPortSpan-1)
	}
	if !loadSettings(filepath.Join(a.dataDir, "settings.json")).LAN {
		t.Fatal("the choice must be saved")
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
	if err != nil {
		t.Fatalf("listener not reachable: %v", err)
	}
	conn.Close()
	if code, out = postApp(t, base, "/app/lan", `{"enabled":false}`); code != 200 || out["enabled"] != false {
		t.Fatalf("disable: %d %v", code, out)
	}
	if loadSettings(filepath.Join(a.dataDir, "settings.json")).LAN {
		t.Fatal("turning it off must be saved")
	}
}
