package launcher

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Model versions are revisions of the Hugging Face model repo: the main branch (latest) and
// every tag. Each version's file hash comes from the Hub API (the LFS sha256), so installing an
// older or newer version is verified like any download. The installed version is found by
// matching the local file's cached fingerprint; nothing extra is stored.

const versionsTTL = 10 * time.Minute

type modelVersion struct {
	Revision  string   `json:"revision"`
	Names     []string `json:"names"` // every ref that points at this file content
	SHA256    string   `json:"sha256"`
	Size      int64    `json:"size"`
	Latest    bool     `json:"latest"`
	Installed bool     `json:"installed"`
}

type versionsCache struct {
	mu   sync.Mutex
	at   map[string]time.Time
	data map[string][]modelVersion
}

var modelVersionsCache = versionsCache{at: map[string]time.Time{}, data: map[string][]modelVersion{}}

type hubRefs struct {
	Branches []hubRef `json:"branches"`
	Tags     []hubRef `json:"tags"`
}

type hubRef struct {
	Name string `json:"name"`
}

type hubPathInfo struct {
	Path string `json:"path"`
	LFS  *struct {
		OID  string `json:"oid"`
		Size int64  `json:"size"`
	} `json:"lfs"`
}

func (u *updater) hubJSON(ctx context.Context, method, endpoint string, body []byte, into any) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", u.ua)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("model hub answered HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(into)
}

// listVersions returns the versions of a tier's file, newest first, main branch first.
func (u *updater) listVersions(ctx context.Context, t Tier, fresh bool) ([]modelVersion, error) {
	key := t.File
	modelVersionsCache.mu.Lock()
	cached, ok := modelVersionsCache.data[key]
	if ok && !fresh && time.Since(modelVersionsCache.at[key]) < versionsTTL {
		modelVersionsCache.mu.Unlock()
		return u.markInstalled(t, cached), nil
	}
	modelVersionsCache.mu.Unlock()

	api := strings.TrimRight(u.models(), "/") + "/api/models/" + u.cfg.Repo
	var refs hubRefs
	if err := u.hubJSON(ctx, http.MethodGet, api+"/refs", nil, &refs); err != nil {
		return nil, err
	}
	revisions := orderRevisions(refs)
	body, _ := json.Marshal(map[string][]string{"paths": {t.File}})
	var versions []modelVersion
	bySHA := map[string]int{}
	for _, rev := range revisions {
		var info []hubPathInfo
		if err := u.hubJSON(ctx, http.MethodPost, api+"/paths-info/"+url.PathEscape(rev), body, &info); err != nil {
			return nil, err
		}
		if len(info) == 0 || info[0].LFS == nil || !sha256Re.MatchString(info[0].LFS.OID) {
			continue // this revision does not have the file
		}
		sha := info[0].LFS.OID
		if i, seen := bySHA[sha]; seen {
			versions[i].Names = append(versions[i].Names, rev)
			continue
		}
		bySHA[sha] = len(versions)
		versions = append(versions, modelVersion{Revision: rev, Names: []string{rev}, SHA256: sha, Size: info[0].LFS.Size, Latest: len(versions) == 0 && rev == u.cfg.Revision})
	}
	modelVersionsCache.mu.Lock()
	modelVersionsCache.data[key], modelVersionsCache.at[key] = versions, time.Now()
	modelVersionsCache.mu.Unlock()
	return u.markInstalled(t, versions), nil
}

// orderRevisions puts the configured branch first, then tags newest first (natural order,
// so v10 sorts after v9), then other branches.
func orderRevisions(refs hubRefs) []string {
	var tags, branches []string
	for _, r := range refs.Tags {
		tags = append(tags, r.Name)
	}
	for _, r := range refs.Branches {
		branches = append(branches, r.Name)
	}
	sort.Slice(tags, func(i, j int) bool { return naturalLess(tags[j], tags[i]) })
	sort.Strings(branches)
	out := make([]string, 0, len(tags)+len(branches))
	for _, b := range branches {
		if b == "main" {
			out = append(out, b)
		}
	}
	out = append(out, tags...)
	for _, b := range branches {
		if b != "main" {
			out = append(out, b)
		}
	}
	return out
}

// naturalLess compares strings with digit runs as numbers: "v2" < "v10".
func naturalLess(a, b string) bool {
	for a != "" && b != "" {
		da, db := digitPrefix(a), digitPrefix(b)
		if da != "" && db != "" {
			na, _ := strconv.Atoi(da)
			nb, _ := strconv.Atoi(db)
			if na != nb {
				return na < nb
			}
			a, b = a[len(da):], b[len(db):]
			continue
		}
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		a, b = a[1:], b[1:]
	}
	return len(a) < len(b)
}

func digitPrefix(s string) string {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return s[:i]
}

// markInstalled flags the version whose hash matches the local file's cached fingerprint.
// It never hashes a multi-gigabyte file just to draw a list.
func (u *updater) markInstalled(t Tier, versions []modelVersion) []modelVersion {
	local := u.cachedSHA(t)
	out := make([]modelVersion, len(versions))
	for i, v := range versions {
		v.Installed = local != "" && v.SHA256 == local
		out[i] = v
	}
	return out
}

func (u *updater) cachedSHA(t Tier) string {
	st, err := os.Stat(u.tierPath(t))
	if err != nil {
		return ""
	}
	u.mu.Lock()
	fp, ok := u.fps[t.File]
	u.mu.Unlock()
	if ok && fp.Size == st.Size() && fp.ModNano == st.ModTime().UnixNano() {
		return fp.SHA256
	}
	return ""
}

func (a *App) registerVersionRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /app/models/versions", func(w http.ResponseWriter, r *http.Request) {
		t, ok := a.cfg.tier(r.URL.Query().Get("tier"))
		if !ok || a.updates == nil {
			writeJSON(w, 400, map[string]any{"error": "unknown model"})
			return
		}
		versions, err := a.updates.listVersions(r.Context(), t, r.URL.Query().Get("refresh") == "1")
		if err != nil {
			writeJSON(w, 502, map[string]any{"error": "Could not load versions: " + err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"repo": a.cfg.Repo, "versions": versions, "installed_known": a.updates.cachedSHA(t) != ""})
	})
	mux.HandleFunc("POST /app/models/install", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Tier     string `json:"tier"`
			Revision string `json:"revision"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req); err != nil || a.updates == nil {
			writeJSON(w, 400, map[string]any{"error": "bad json"})
			return
		}
		t, ok := a.cfg.tier(req.Tier)
		if !ok {
			writeJSON(w, 400, map[string]any{"error": "unknown model"})
			return
		}
		// Only a revision from the listed versions is accepted, with the hash the Hub reported.
		versions, err := a.updates.listVersions(r.Context(), t, false)
		if err != nil {
			writeJSON(w, 502, map[string]any{"error": "Could not load versions: " + err.Error()})
			return
		}
		for _, v := range versions {
			if v.Revision == req.Revision {
				if err := a.updates.startVersionDownload(t.ID, v.Revision, v.SHA256, v.Size); err != nil {
					writeJSON(w, 409, map[string]any{"error": map[string]any{"code": errCode(err), "message": err.Error()}})
					return
				}
				writeJSON(w, 200, map[string]any{"installing": v.Revision})
				return
			}
		}
		writeJSON(w, 404, map[string]any{"error": "unknown version"})
	})
}

func errCode(err error) string {
	if pe, ok := err.(*PermanentError); ok {
		return pe.Code
	}
	return "error"
}
