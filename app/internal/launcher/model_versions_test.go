package launcher

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeHub serves the parts of the Hugging Face Hub the version list and downloads use.
func fakeHub(t *testing.T, repo, file string, byRev map[string][]byte, tags []string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		api := "/api/models/" + repo
		switch {
		case r.URL.Path == api+"/refs":
			refs := map[string][]map[string]string{"branches": {{"name": "main"}}}
			for _, tag := range tags {
				refs["tags"] = append(refs["tags"], map[string]string{"name": tag})
			}
			_ = json.NewEncoder(w).Encode(refs)
		case strings.HasPrefix(r.URL.Path, api+"/paths-info/"):
			content, ok := byRev[strings.TrimPrefix(r.URL.Path, api+"/paths-info/")]
			if !ok {
				_ = json.NewEncoder(w).Encode([]any{})
				return
			}
			_ = json.NewEncoder(w).Encode([]any{map[string]any{"path": file, "lfs": map[string]any{"oid": sha(content), "size": len(content)}}})
		case strings.HasPrefix(r.URL.Path, "/"+repo+"/resolve/"):
			rev := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/"+repo+"/resolve/"), "/", 2)[0]
			content, ok := byRev[rev]
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("X-Linked-Size", strconv.Itoa(len(content)))
			w.Header().Set("X-Linked-Etag", `"`+sha(content)+`"`)
			http.ServeContent(w, r, file, time.Time{}, bytes.NewReader(content))
		default:
			http.NotFound(w, r)
		}
	}))
}

func ggufBytes(seed byte, n int) []byte {
	b := append([]byte("GGUF"), bytes.Repeat([]byte{seed}, n)...)
	return b
}

func TestModelVersionsListAndDowngrade(t *testing.T) {
	cfg := testConfig(t)
	tier, _ := cfg.tier("q6")
	latest, v2, v1 := ggufBytes(3, 4096), ggufBytes(2, 4096), ggufBytes(1, 4096)
	hub := fakeHub(t, cfg.Repo, tier.File, map[string][]byte{"main": latest, "v10": latest, "v2": v2, "v1": v1}, []string{"v1", "v2", "v10"})
	defer hub.Close()
	u, _ := newTestUpdater(t, "", hub.URL)

	local := u.tierPath(tier)
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, latest, 0o600); err != nil {
		t.Fatal(err)
	}
	u.recordFP(tier.File, local, sha(latest))

	versions, err := u.listVersions(context.Background(), tier, true)
	if err != nil {
		t.Fatal(err)
	}
	var got [][]string
	for _, v := range versions {
		got = append(got, v.Names)
	}
	if want := [][]string{{"main", "v10"}, {"v2"}, {"v1"}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("versions = %v, want %v", got, want)
	}
	if !versions[0].Latest || !versions[0].Installed || versions[2].Installed {
		t.Fatalf("latest/installed flags wrong: %+v", versions)
	}

	if err := u.startVersionDownload(tier.ID, "v1", versions[2].SHA256, versions[2].Size); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "downgrade to v1", 10*time.Second, func() bool {
		b, err := os.ReadFile(local)
		return err == nil && bytes.Equal(b, v1)
	})
	waitFor(t, "fingerprint of v1", 5*time.Second, func() bool { return u.cachedSHA(tier) == sha(v1) })
	versions, _ = u.listVersions(context.Background(), tier, false)
	if !versions[2].Installed || versions[0].Installed {
		t.Fatalf("after downgrade the installed version should be v1: %+v", versions)
	}
}

func TestStartVersionDownloadRejectsUnverifiedVersion(t *testing.T) {
	u, _ := newTestUpdater(t, "", "http://127.0.0.1:9")
	if err := u.startVersionDownload("q6", "v1", "not-a-sha", 10); errCode(err) != "bad_version" {
		t.Fatalf("err = %v, want bad_version", err)
	}
}

func TestNaturalLess(t *testing.T) {
	tests := []struct {
		a, b string
		want bool
	}{{"v2", "v10", true}, {"v10", "v2", false}, {"v1.2", "v1.10", true}, {"a", "b", true}, {"v1", "v1", false}}
	for _, tt := range tests {
		if got := naturalLess(tt.a, tt.b); got != tt.want {
			t.Errorf("naturalLess(%q, %q) = %v, want %v", tt.a, tt.b, got, tt.want)
		}
	}
}
