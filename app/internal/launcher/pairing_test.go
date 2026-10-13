package launcher

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestPairingCodeLifecycle(t *testing.T) {
	now := time.Now()
	tests := []struct {
		name    string
		advance time.Duration
		typed   func(code string) string
		wantErr error
	}{
		{"exact code", 0, func(c string) string { return c }, nil},
		{"lower case with dash", 0, func(c string) string { return strings.ToLower(c[:3] + "-" + c[3:]) }, nil},
		{"expired", pairCodeTTL + time.Second, func(c string) string { return c }, errPairExpired},
		{"wrong code", 0, func(string) string { return "AAAAAA" }, errWrongPair},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := loadPairings(filepath.Join(t.TempDir(), "pairings.json"))
			code := s.startCode(now).code
			_, key, err := s.redeem(tt.typed(code), "Browser", now.Add(tt.advance))
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if tt.wantErr == nil {
				if _, ok := s.authenticate(key, now); !ok {
					t.Fatal("the issued key must authenticate")
				}
			}
		})
	}
}

func TestPairingCodeLocksAfterWrongAttempts(t *testing.T) {
	s := loadPairings(filepath.Join(t.TempDir(), "pairings.json"))
	now := time.Now()
	code := s.startCode(now).code
	var err error
	for i := 0; i < pairCodeAttempts; i++ {
		_, _, err = s.redeem("AAAAAA", "x", now)
	}
	if !errors.Is(err, errPairExhausted) {
		t.Fatalf("after %d wrong codes err = %v, want exhausted", pairCodeAttempts, err)
	}
	if _, _, err = s.redeem(code, "x", now); !errors.Is(err, errNoPairCode) {
		t.Fatalf("the right code must not work after lockout, err = %v", err)
	}
}

func TestPairingStoresOnlyKeyHashAndSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pairings.json")
	s := loadPairings(path)
	now := time.Now()
	b, key, err := s.redeem(s.startCode(now).code, "  Firefox   on Linux ", now)
	if err != nil {
		t.Fatal(err)
	}
	if b.Name != "Firefox on Linux" {
		t.Fatalf("name not cleaned: %q", b.Name)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), key) {
		t.Fatal("pairings.json must not contain the key itself")
	}
	if st, _ := os.Stat(path); runtime.GOOS != "windows" && st.Mode().Perm() != 0o600 { // Windows has no Unix modes
		t.Fatalf("pairings.json mode = %v, want 0600", st.Mode().Perm())
	}
	reloaded := loadPairings(path)
	if _, ok := reloaded.authenticate(key, now); !ok {
		t.Fatal("pairing must survive an app restart")
	}
	if !reloaded.remove(b.ID, now) {
		t.Fatal("remove should find the browser")
	}
	if _, ok := reloaded.authenticate(key, now); ok {
		t.Fatal("a removed browser must not authenticate")
	}
}

func TestRandomCodeUsesUnambiguousAlphabet(t *testing.T) {
	for i := 0; i < 200; i++ {
		code := randomCode()
		if len(code) != pairCodeLength || normalizeCode(code) != code {
			t.Fatalf("bad code %q", code)
		}
	}
}
