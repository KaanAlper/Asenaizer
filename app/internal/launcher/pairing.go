package launcher

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Browsers pair with this device by typing a short code that the tray shows. Each paired
// browser gets its own random key; only the key's SHA-256 is stored, so pairings.json
// cannot be used to impersonate a browser. Keys survive restarts, which lets the website
// reconnect on its own until the user forgets the device or removes the browser.

const (
	pairCodeTTL      = 5 * time.Minute
	pairCodeAttempts = 5
	pairCodeLength   = 6
	// No 0/O, 1/I/L: the code is read off one screen and typed on another.
	pairCodeAlphabet  = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	pairNameMax       = 60
	pairSeenSaveEvery = 10 * time.Minute
)

var (
	errNoPairCode    = errors.New("no pairing code is active; select Connect a browser in the app")
	errWrongPair     = errors.New("that code is not correct")
	errPairExpired   = errors.New("the code has expired; create a new one in the app")
	errPairExhausted = errors.New("too many wrong codes; create a new one in the app")
)

type pairedBrowser struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	KeyHash  string    `json:"key_hash"`
	Created  time.Time `json:"created"`
	LastSeen time.Time `json:"last_seen"`
	// Paused browsers stay paired but are refused until they reconnect. The tray's
	// Disconnect sets it; the website's Reconnect or the tray's Reconnect clears it.
	Paused bool `json:"paused,omitempty"`
}

type pendingCode struct {
	code     string
	expires  time.Time
	attempts int
}

type pairingStore struct {
	mu        sync.Mutex
	path      string
	browsers  []pairedBrowser
	pending   *pendingCode
	lastPair  *pairedBrowser // shown by the tray right after a browser pairs
	lastSaved time.Time
}

func loadPairings(path string) *pairingStore {
	s := &pairingStore{path: path}
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &s.browsers)
	}
	return s
}

// pairing returns the store, creating it on first use (tests build App by hand).
func (a *App) pairing() *pairingStore {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.pairings == nil {
		a.pairings = loadPairings(filepath.Join(a.dataDir, "pairings.json"))
	}
	return a.pairings
}

// randomCode draws each character uniformly by rejecting bytes past the last full
// multiple of the alphabet size.
func randomCode() string {
	limit := byte(256 - 256%len(pairCodeAlphabet))
	out := make([]byte, 0, pairCodeLength)
	buf := make([]byte, 16)
	for len(out) < pairCodeLength {
		if _, err := rand.Read(buf); err != nil {
			panic(err)
		}
		for _, v := range buf {
			if v < limit && len(out) < pairCodeLength {
				out = append(out, pairCodeAlphabet[int(v)%len(pairCodeAlphabet)])
			}
		}
	}
	return string(out)
}

// normalizeCode accepts "k7q-4mz", "K7Q 4MZ" and similar spellings.
func normalizeCode(code string) string {
	var out strings.Builder
	for _, r := range strings.ToUpper(code) {
		if strings.ContainsRune(pairCodeAlphabet, r) {
			out.WriteRune(r)
		}
	}
	return out.String()
}

func hashKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

func cleanName(name string) string {
	name = strings.Join(strings.Fields(name), " ")
	if name == "" {
		return "Web browser"
	}
	if r := []rune(name); len(r) > pairNameMax {
		name = string(r[:pairNameMax])
	}
	return name
}

// startCode replaces any active code with a fresh one.
func (s *pairingStore) startCode(now time.Time) pendingCode {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pending = &pendingCode{code: randomCode(), expires: now.Add(pairCodeTTL)}
	s.lastPair = nil
	return *s.pending
}

func (s *pairingStore) cancelCode() {
	s.mu.Lock()
	s.pending = nil
	s.mu.Unlock()
}

// pairState is what the tray's waiting screen polls.
func (s *pairingStore) pairState(now time.Time) (code string, left time.Duration, paired *pairedBrowser) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending != nil && now.After(s.pending.expires) {
		s.pending = nil
	}
	if s.pending != nil {
		code, left = s.pending.code, s.pending.expires.Sub(now)
	}
	if s.lastPair != nil {
		p := *s.lastPair
		paired = &p
	}
	return code, left, paired
}

// redeem checks a code typed on the website and, if it matches, pairs a new browser.
// It returns the browser's key, which is never stored in plain form.
func (s *pairingStore) redeem(code, name string, now time.Time) (pairedBrowser, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.pending
	switch {
	case p == nil:
		return pairedBrowser{}, "", errNoPairCode
	case now.After(p.expires):
		s.pending = nil
		return pairedBrowser{}, "", errPairExpired
	}
	if subtle.ConstantTimeCompare([]byte(normalizeCode(code)), []byte(p.code)) != 1 {
		p.attempts++
		if p.attempts >= pairCodeAttempts {
			s.pending = nil
			return pairedBrowser{}, "", errPairExhausted
		}
		return pairedBrowser{}, "", errWrongPair
	}
	key := randomKey()
	b := pairedBrowser{ID: randomKey()[:12], Name: cleanName(name), KeyHash: hashKey(key), Created: now, LastSeen: now}
	s.browsers = append(s.browsers, b)
	s.pending = nil
	s.lastPair = &b
	if err := s.saveLocked(now); err != nil {
		s.browsers = s.browsers[:len(s.browsers)-1]
		return pairedBrowser{}, "", err
	}
	return b, key, nil
}

// authenticate finds the browser that owns key.
func (s *pairingStore) authenticate(key string, now time.Time) (pairedBrowser, bool) {
	if key == "" {
		return pairedBrowser{}, false
	}
	want := []byte(hashKey(key))
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.browsers {
		if subtle.ConstantTimeCompare(want, []byte(s.browsers[i].KeyHash)) == 1 {
			s.browsers[i].LastSeen = now
			if now.Sub(s.lastSaved) > pairSeenSaveEvery {
				_ = s.saveLocked(now)
			}
			return s.browsers[i], true
		}
	}
	return pairedBrowser{}, false
}

// setPaused pauses or resumes one browser, or every browser when id is empty.
// It reports how many browsers changed.
func (s *pairingStore) setPaused(id string, paused bool, now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := 0
	for i := range s.browsers {
		if (id == "" || s.browsers[i].ID == id) && s.browsers[i].Paused != paused {
			s.browsers[i].Paused = paused
			changed++
		}
	}
	if changed > 0 {
		_ = s.saveLocked(now)
	}
	return changed
}

func (s *pairingStore) list() []pairedBrowser {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]pairedBrowser(nil), s.browsers...)
}

func (s *pairingStore) remove(id string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.browsers[:0:0]
	for _, b := range s.browsers {
		if b.ID != id {
			kept = append(kept, b)
		}
	}
	if len(kept) == len(s.browsers) {
		return false
	}
	s.browsers = kept
	_ = s.saveLocked(now)
	return true
}

func (s *pairingStore) saveLocked(now time.Time) error {
	b, err := json.MarshalIndent(s.browsers, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	if err := writeFileAtomic(s.path, b); err != nil {
		return err
	}
	_ = os.Chmod(s.path, 0o600)
	s.lastSaved = now
	return nil
}

func (a *App) registerPairingRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /app/pair/start", func(w http.ResponseWriter, r *http.Request) {
		p := a.pairing().startCode(time.Now())
		writeJSON(w, 200, map[string]any{"code": p.code, "expires_in": int(pairCodeTTL / time.Second), "device": deviceName()})
	})
	mux.HandleFunc("POST /app/pair/cancel", func(w http.ResponseWriter, r *http.Request) {
		a.pairing().cancelCode()
		writeJSON(w, 200, map[string]any{"ok": true})
	})
	mux.HandleFunc("GET /app/pair/state", func(w http.ResponseWriter, r *http.Request) {
		code, left, paired := a.pairing().pairState(time.Now())
		resp := map[string]any{"code": code, "expires_in": int(left / time.Second), "device": deviceName()}
		if paired != nil {
			resp["paired"] = map[string]any{"id": paired.ID, "name": paired.Name}
		}
		writeJSON(w, 200, resp)
	})
	mux.HandleFunc("GET /app/pairings", func(w http.ResponseWriter, r *http.Request) {
		list := a.pairing().list()
		out := make([]map[string]any, 0, len(list))
		for _, b := range list {
			out = append(out, map[string]any{"id": b.ID, "name": b.Name, "created": b.Created, "last_seen": b.LastSeen, "paused": b.Paused})
		}
		writeJSON(w, 200, map[string]any{"browsers": out})
	})
	// Disconnect stops the website from using this computer without forgetting the browser.
	mux.HandleFunc("POST /app/pairings/disconnect", func(w http.ResponseWriter, r *http.Request) {
		id := pairingID(w, r)
		n := a.pairing().setPaused(id, true, time.Now())
		a.lastBridge.Store(0)
		if a.inflight.Load() == 0 {
			a.unloadEngine("disconnected from the tray")
		}
		writeJSON(w, 200, map[string]any{"paused": n})
	})
	mux.HandleFunc("POST /app/pairings/resume", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"resumed": a.pairing().setPaused(pairingID(w, r), false, time.Now())})
	})
	mux.HandleFunc("POST /app/pairings/remove", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil || req.ID == "" {
			writeJSON(w, 400, map[string]any{"error": "bad json"})
			return
		}
		if !a.pairing().remove(req.ID, time.Now()) {
			writeJSON(w, 404, map[string]any{"error": "unknown browser"})
			return
		}
		writeJSON(w, 200, map[string]any{"removed": req.ID})
	})
}

// pairingID reads an optional {"id": "..."} body; an empty id means every browser.
func pairingID(w http.ResponseWriter, r *http.Request) string {
	var req struct {
		ID string `json:"id"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req)
	return req.ID
}
