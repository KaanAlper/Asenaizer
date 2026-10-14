package launcher

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Other computers on the local network can use this device's model. The public website
// cannot reach them: browsers block an HTTPS page from calling a plain-HTTP address on the
// network, and the main listener only accepts 127.0.0.1. So, when the user turns it on, a
// second listener serves the website itself on every interface, and the other computer
// opens http://<this computer>:47630/ and pairs with a code as usual.
//
// That listener serves the website's files and the paired /bridge/* routes, nothing else:
// /app/* and /api/* stay on 127.0.0.1. Its traffic is not encrypted, which the tray says.

const (
	lanPortBase = 47630 // outside 47615..47624, the range the website probes on 127.0.0.1
	lanPortSpan = 10
)

// lanListenHost is empty (every interface); tests set 127.0.0.1 so no firewall prompt appears.
var lanListenHost = ""

// siteFiles are the website's files (docs/ in the repository), copied next to the service
// as site/ by the packagers.
var siteFiles = []string{"index.html", "app.js", "style.css", "theme.js", "favicon.svg", "apple-touch-icon.png"}

type lanServer struct {
	srv  *http.Server
	port int
}

// defaultSiteDir is site/ next to the executable.
func defaultSiteDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if p, err := filepath.EvalSymlinks(exe); err == nil {
		exe = p
	}
	return filepath.Join(filepath.Dir(exe), "site")
}

func (a *App) siteAvailable() bool {
	return a.siteDir != "" && fileExists(filepath.Join(a.siteDir, "index.html"))
}

// startLAN opens the network listener on the first free port of 47630..47639.
func (a *App) startLAN() error {
	a.lanMu.Lock()
	defer a.lanMu.Unlock()
	if a.lan != nil {
		return nil
	}
	if !a.siteAvailable() {
		a.lanErr = "This build has no website files (site folder)."
		return errors.New(a.lanErr)
	}
	var ln net.Listener
	var err error
	for p := lanPortBase; p < lanPortBase+lanPortSpan; p++ {
		if ln, err = net.Listen("tcp", net.JoinHostPort(lanListenHost, strconv.Itoa(p))); err == nil {
			break
		}
	}
	if err != nil {
		a.lanErr = "No free network port in 47630-47639."
		return fmt.Errorf("%s %w", a.lanErr, err)
	}
	srv := &http.Server{Handler: a.lanHandler(), ReadHeaderTimeout: 10 * time.Second}
	a.lan = &lanServer{srv: srv, port: ln.Addr().(*net.TCPAddr).Port}
	a.lanErr = ""
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			a.logf("network listener stopped: %v", err)
		}
	}()
	a.logf("other computers can connect on port %d", a.lan.port)
	return nil
}

func (a *App) stopLAN() {
	a.lanMu.Lock()
	l := a.lan
	a.lan = nil
	a.lanMu.Unlock()
	if l != nil {
		_ = l.srv.Close()
		a.logf("network listener closed")
	}
}

func (a *App) lanHandler() http.Handler {
	mux := http.NewServeMux()
	a.registerBridgeRoutes(mux)
	mux.Handle("GET /", a.siteHandler())
	bridge := a.bridgeAuth(mux)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A DNS name that is not this computer's means DNS rebinding.
		if !lanHostOK(r.Host, deviceName()) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		// The page calls its own origin; browsers leave Origin out of same-origin GETs.
		if o := r.Header.Get("Origin"); o != "" && o != "http://"+r.Host {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/bridge/") {
			w.Header().Set("Cache-Control", "no-store")
			bridge.ServeHTTP(w, r)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

// siteHandler serves only the listed website files.
func (a *App) siteHandler() http.Handler {
	allowed := map[string]bool{"/": true}
	for _, f := range siteFiles {
		allowed["/"+f] = true
	}
	files := http.FileServerFS(os.DirFS(a.siteDir))
	csp := "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; " +
		"connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowed[r.URL.Path] {
			http.NotFound(w, r)
			return
		}
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		h.Set("Cache-Control", "no-cache")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		files.ServeHTTP(w, r)
	})
}

// lanHostOK accepts an IP address or this computer's own name, with or without .local.
func lanHostOK(host, device string) bool {
	h, _, err := net.SplitHostPort(host)
	if err != nil {
		h = host
	}
	h = strings.TrimSuffix(strings.Trim(h, "[]"), ".")
	if h == "" {
		return false
	}
	if net.ParseIP(h) != nil {
		return true
	}
	return strings.EqualFold(h, device) || strings.EqualFold(h, device+".local")
}

type lanAddress struct {
	URL       string `json:"url"`
	Interface string `json:"interface"`
}

// lanAddresses lists the addresses other computers can use, home networks first and
// virtual adapters (WSL, Hyper-V, VirtualBox, Docker) last.
func lanAddresses(port int) []lanAddress {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	type ranked struct {
		lanAddress
		rank int
	}
	var out []ranked
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP.To4()
			if ip == nil || ip.IsLinkLocalUnicast() {
				continue
			}
			out = append(out, ranked{lanAddress{URL: fmt.Sprintf("http://%s:%d/", ip, port), Interface: iface.Name}, addressRank(ip, iface.Name)})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].rank < out[j].rank })
	list := make([]lanAddress, len(out))
	for i := range out {
		list[i] = out[i].lanAddress
	}
	return list
}

func addressRank(ip net.IP, iface string) int {
	name := strings.ToLower(iface)
	for _, v := range []string{"vethernet", "virtualbox", "vmware", "vmnet", "docker", "br-", "veth", "virbr", "wsl", "hyper-v"} {
		if strings.Contains(name, v) {
			return 9
		}
	}
	switch {
	case ip[0] == 192 && ip[1] == 168:
		return 0
	case ip[0] == 10:
		return 1
	case ip[0] == 172 && ip[1]&0xf0 == 16:
		return 2
	case ip[0] == 100 && ip[1]&0xc0 == 64: // Tailscale and other overlay networks
		return 3
	}
	return 5
}

type lanStatus struct {
	Enabled   bool         `json:"enabled"`
	Port      int          `json:"port,omitempty"`
	Addresses []lanAddress `json:"addresses"`
	Device    string       `json:"device"`
	Site      bool         `json:"site"`
	Error     string       `json:"error,omitempty"`
}

func (a *App) lanStatus() lanStatus {
	s := lanStatus{Device: deviceName(), Site: a.siteAvailable(), Addresses: []lanAddress{}}
	a.lanMu.Lock()
	if a.lan != nil {
		s.Enabled, s.Port = true, a.lan.port
	}
	s.Error = a.lanErr
	a.lanMu.Unlock()
	if s.Enabled {
		s.Addresses = lanAddresses(s.Port)
	}
	return s
}

func (a *App) registerLANRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /app/lan", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, a.lanStatus())
	})
	mux.HandleFunc("POST /app/lan", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Enabled *bool `json:"enabled"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil || req.Enabled == nil {
			writeJSON(w, 400, map[string]any{"error": "bad json"})
			return
		}
		if *req.Enabled {
			if err := a.startLAN(); err != nil {
				a.logf("could not let other computers connect: %v", err)
			}
		} else {
			a.stopLAN()
		}
		st := a.lanStatus()
		a.mu.Lock()
		a.settings.LAN = st.Enabled
		s := a.settings
		a.mu.Unlock()
		_ = saveSettings(a.settingsPath(), s)
		writeJSON(w, 200, st)
	})
}
