// pkgmirror-web — monitoring & operations UI for the pkgmirror build box.
//
// A thin, stdlib-only orchestration layer: it reads config via dasel, reads build
// state files, queries systemd/journald, and shells out to the existing bin/*.sh
// scripts. Bash remains the single source of truth for build logic. Runs as the
// `pkgmirror` user (which has full NOPASSWD sudo) behind nginx; no auth (LAN trust).
package main

import (
	"bufio"
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed static
var staticFS embed.FS

var (
	root    = env("PKGMIRROR_ROOT", "/opt/pkgmirror")
	data    = env("PKGMIRROR_DATA", "/srv/pkgmirror")
	dasel   = env("DASEL", "/usr/local/bin/dasel")
	addr    = env("PKGMIRROR_WEB_ADDR", "127.0.0.1:8080")
	nameRe  = regexp.MustCompile(`^[A-Za-z0-9._+-]+$`)
	unitRe  = regexp.MustCompile(`^pkgmirror-(adhoc-[0-9]+|build@[A-Za-z0-9._+-]+)(\.service)?$`)
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	mux := http.NewServeMux()

	// Static SPA (embedded).
	sub, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /", http.FileServer(http.FS(sub)))

	mux.HandleFunc("GET /api/status", hStatus)
	mux.HandleFunc("POST /api/build", hBuild)
	mux.HandleFunc("GET /api/logs/stream", hLogStream)
	mux.HandleFunc("GET /api/logs/build/{arch}/{pkg}/{ts}", hBuildLog)
	mux.HandleFunc("GET /api/builds", hAllBuilds)
	mux.HandleFunc("GET /api/builds/{arch}", hBuilds)
	mux.HandleFunc("GET /api/history/{arch}/{pkg}", hPkgHistory)
	mux.HandleFunc("POST /api/packages/{arch}", hAddPackage)
	mux.HandleFunc("DELETE /api/packages/{arch}/{pkg}", hRemovePackage)
	mux.HandleFunc("GET /api/pkgbuild/{arch}/{pkg}", hGetPkgbuild)
	mux.HandleFunc("PUT /api/pkgbuild/{arch}/{pkg}", hPutPkgbuild)
	mux.HandleFunc("POST /api/chroot/{arch}/bootstrap", hBootstrap)
	mux.HandleFunc("POST /api/update-check/{arch}", hUpdateCheck)
	mux.HandleFunc("POST /api/groups", hCreateGroup)
	mux.HandleFunc("POST /api/groups/{group}/packages/{pkg}", hGroupAdd)
	mux.HandleFunc("DELETE /api/groups/{group}/packages/{pkg}", hGroupRemove)
	mux.HandleFunc("POST /api/arches/{arch}/groups/{group}", hArchGroupEnable)
	mux.HandleFunc("DELETE /api/arches/{arch}/groups/{group}", hArchGroupDisable)
	mux.HandleFunc("POST /api/pause", hControl("pause"))
	mux.HandleFunc("POST /api/resume", hControl("resume"))
	mux.HandleFunc("POST /api/stop", hControl("stop"))

	log.Printf("pkgmirror-web listening on %s (root=%s data=%s)", addr, root, data)
	log.Fatal(http.ListenAndServe(addr, logReq(mux)))
}

func logReq(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		h.ServeHTTP(w, r)
	})
}

// ---- helpers ---------------------------------------------------------------

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
func httpErr(w http.ResponseWriter, code int, msg string) {
	http.Error(w, msg, code)
}

func run(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// dget reads a scalar via dasel and strips its surrounding quotes.
func dget(file, sel string) string {
	out, err := run(dasel, "-f", file, "-r", "toml", sel)
	if err != nil {
		return ""
	}
	return strings.Trim(out, "'\"")
}

func archConf(a string) string  { return filepath.Join(root, "config/arches", a+".toml") }
func pkgList(a string) string   { return filepath.Join(root, "config/packages", a+".toml") }

func arches() []string {
	var out []string
	files, _ := filepath.Glob(filepath.Join(root, "config/arches", "*.toml"))
	for _, f := range files {
		out = append(out, strings.TrimSuffix(filepath.Base(f), ".toml"))
	}
	sort.Strings(out)
	return out
}
func archExists(a string) bool {
	if !nameRe.MatchString(a) {
		return false
	}
	_, err := os.Stat(archConf(a))
	return err == nil
}

// repoVersion returns the newest built pkgver-pkgrel for pkg in arch's repo.
func repoVersion(arch, pkg string) string {
	files, _ := filepath.Glob(filepath.Join(data, "repos", arch, pkg+"-*.pkg.tar.zst"))
	newest := ""
	for _, f := range files {
		b := strings.TrimSuffix(filepath.Base(f), ".pkg.tar.zst")
		b = strings.TrimPrefix(b, pkg+"-")
		if i := strings.LastIndex(b, "-"); i > 0 { // drop trailing -<arch>
			b = b[:i]
		}
		newest = b
	}
	return newest
}

// pkgbuildVersion sources a PKGBUILD in bash and returns pkgver-pkgrel (or "").
func pkgbuildVersion(dir string) string {
	if _, err := os.Stat(filepath.Join(dir, "PKGBUILD")); err != nil {
		return ""
	}
	out, err := run("bash", "-c",
		`set +eu; source "$1/PKGBUILD" >/dev/null 2>&1; printf '%s-%s' "${pkgver:-}" "${pkgrel:-}"`,
		"_", dir)
	if err != nil || out == "-" {
		return ""
	}
	return out
}

// ---- status ----------------------------------------------------------------

type pkgInfo struct {
	Name    string `json:"name"`
	Source  string `json:"source"`
	Origin  string `json:"origin"`
	RepoVer string `json:"repo_version"`
	SrcVer  string `json:"source_version"`
	Local   bool   `json:"local"`
	Due     bool   `json:"due"`
	// Build outcome history (from state/<arch>/history.jsonl), 0/"" if never built.
	LastBuild  int64  `json:"last_build,omitempty"`  // end time of the most recent attempt
	LastResult string `json:"last_result,omitempty"` // "ok" | "failed" for that attempt
	LastOk     int64  `json:"last_ok,omitempty"`     // end time of the most recent success
}
type archInfo struct {
	Name          string          `json:"name"`
	Base          string          `json:"base"`
	CFlags        string          `json:"cflags"`
	ChrootReady   bool            `json:"chroot_ready"`
	TimerNext     string          `json:"timer_next"`
	EnabledGroups []string        `json:"enabled_groups"`
	LastBuild     json.RawMessage `json:"last_build,omitempty"`
	Current       *curBuild       `json:"current,omitempty"`
	Packages      []pkgInfo       `json:"packages"`
}

// curBuild is the live view of an in-flight build sweep for one arch, assembled
// from state/<arch>/current.json (written by build.sh at start) plus the
// per-package progress markers in state/<arch>/progress/. Nil when idle.
type curBuild struct {
	Unit     string   `json:"unit"`
	Filter   string   `json:"filter"`
	Started  int64    `json:"started"`
	Jobs     int      `json:"jobs"`
	Total    int      `json:"total"`
	Packages []curPkg `json:"packages"`
}
type curPkg struct {
	Name   string `json:"name"`
	Status string `json:"status"` // pending | building | ok | failed
	At     int64  `json:"at,omitempty"`
}

// currentBuild reads the live build descriptor for arch a, merging each selected
// package with its progress marker. Returns nil when no build is in flight.
func currentBuild(a string) *curBuild {
	sdir := filepath.Join(data, "state", a)
	b, err := os.ReadFile(filepath.Join(sdir, "current.json"))
	if err != nil {
		return nil
	}
	var raw struct {
		Unit     string   `json:"unit"`
		Filter   string   `json:"filter"`
		Started  int64    `json:"started"`
		Jobs     int      `json:"jobs"`
		Total    int      `json:"total"`
		Packages []string `json:"packages"`
	}
	if json.Unmarshal(b, &raw) != nil {
		return nil
	}
	cb := &curBuild{Unit: raw.Unit, Filter: raw.Filter, Started: raw.Started, Jobs: raw.Jobs, Total: raw.Total}
	for _, name := range raw.Packages {
		p := curPkg{Name: name, Status: "pending"}
		if pb, err := os.ReadFile(filepath.Join(sdir, "progress", name)); err == nil {
			f := strings.SplitN(strings.TrimSpace(string(pb)), "\t", 2)
			if f[0] != "" {
				p.Status = f[0]
			}
			if len(f) == 2 {
				p.At, _ = strconv.ParseInt(f[1], 10, 64)
			}
		}
		cb.Packages = append(cb.Packages, p)
	}
	return cb
}
type groupInfo struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Packages    []string `json:"packages"`
}

// effective_packages via the bash helper (single source of truth): name<TAB>source<TAB>origin.
func packagesFor(arch string) []pkgInfo {
	out, err := run("bash", "-c",
		`source "$1/bin/lib/common.sh"; effective_packages "$2"`, "_", root, arch)
	if err != nil {
		return nil
	}
	stats := buildStats(arch)
	var pkgs []pkgInfo
	for _, line := range strings.Split(out, "\n") {
		f := strings.SplitN(line, "\t", 3)
		if len(f) < 3 || f[0] == "" {
			continue
		}
		p := pkgInfo{Name: f[0], Source: f[1], Origin: f[2], RepoVer: repoVersion(arch, f[0])}
		localDir := filepath.Join(root, "pkgbuilds", arch, p.Name)
		if _, err := os.Stat(filepath.Join(localDir, "PKGBUILD")); err == nil {
			p.Local = true
			p.SrcVer = pkgbuildVersion(localDir)
			p.Due = p.SrcVer != "" && p.RepoVer != p.SrcVer
		} else {
			p.Due = p.RepoVer == ""
		}
		if s, ok := stats[p.Name]; ok {
			p.LastBuild, p.LastResult, p.LastOk = s.LastEnd, s.LastResult, s.LastOk
		}
		pkgs = append(pkgs, p)
	}
	return pkgs
}

// pkgStat is a per-package rollup of build outcomes across history.
type pkgStat struct {
	LastEnd    int64  // end time of the most recent attempt (any result)
	LastResult string // result of that most recent attempt
	LastOk     int64  // end time of the most recent successful attempt
}

// buildStats folds state/<arch>/history.jsonl into per-package last-attempt and
// last-success timestamps. Each line is one build sweep with per-package results;
// we keep, per package, the newest attempt and the newest "ok". Empty if no
// history yet. Cheap enough to recompute per /api/status call for a LAN tool.
func buildStats(arch string) map[string]pkgStat {
	m := map[string]pkgStat{}
	fh, err := os.Open(filepath.Join(data, "state", arch, "history.jsonl"))
	if err != nil {
		return m
	}
	defer fh.Close()
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var rec struct {
			End      int64 `json:"end"`
			Start    int64 `json:"start"`
			Packages []struct {
				Name   string `json:"name"`
				Result string `json:"result"`
			} `json:"packages"`
		}
		if json.Unmarshal(line, &rec) != nil {
			continue
		}
		ts := rec.End
		if ts == 0 {
			ts = rec.Start
		}
		for _, p := range rec.Packages {
			s := m[p.Name]
			if ts >= s.LastEnd {
				s.LastEnd, s.LastResult = ts, p.Result
			}
			if p.Result == "ok" && ts >= s.LastOk {
				s.LastOk = ts
			}
			m[p.Name] = s
		}
	}
	return m
}

// dlist reads a dasel array selector into a []string (quotes stripped).
func dlist(file, sel string) []string {
	out, err := run(dasel, "-f", file, "-r", "toml", sel)
	if err != nil {
		return nil
	}
	var vals []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.Trim(l, "'\"")
		if l != "" {
			vals = append(vals, l)
		}
	}
	return vals
}

func groupsAll() []groupInfo {
	var out []groupInfo
	files, _ := filepath.Glob(filepath.Join(root, "config/groups", "*.toml"))
	sort.Strings(files)
	for _, f := range files {
		out = append(out, groupInfo{
			Name:        strings.TrimSuffix(filepath.Base(f), ".toml"),
			Description: dget(f, ".description"),
			Packages:    dlist(f, ".packages.all()"),
		})
	}
	return out
}

func hStatus(w http.ResponseWriter, r *http.Request) {
	type resp struct {
		Arches  []archInfo  `json:"arches"`
		Groups  []groupInfo `json:"groups"`
		Paused  bool        `json:"paused"`
		Running []string    `json:"running"`
		Disk    diskInfo    `json:"disk"`
		CPUPct  int         `json:"cpuPct"`
		Now     int64       `json:"now"`
	}
	var res resp
	res.Now = time.Now().Unix()
	res.Groups = groupsAll()
	res.Paused = fileExists(filepath.Join(data, "state", "paused"))
	for _, a := range arches() {
		ai := archInfo{
			Name:          a,
			Base:          dget(archConf(a), ".base"),
			CFlags:        dget(archConf(a), ".cflags"),
			ChrootReady:   fileExists(filepath.Join(data, "chroots", a, "root", ".pkgmirror-ready")),
			EnabledGroups: dlist(archConf(a), ".groups.all()"),
			Packages:      packagesFor(a),
		}
		if b, err := os.ReadFile(filepath.Join(data, "state", a, "last-build.json")); err == nil {
			ai.LastBuild = json.RawMessage(b)
		}
		ai.Current = currentBuild(a)
		if t, err := run("systemctl", "show", "pkgmirror-build@"+a+".timer",
			"-p", "NextElapseUSecRealtime", "--value"); err == nil {
			ai.TimerNext = t
		}
		res.Arches = append(res.Arches, ai)
	}
	if u, err := run("systemctl", "list-units", "--plain", "--no-legend", "--state=active",
		"pkgmirror-build@*.service", "pkgmirror-adhoc-*.service"); err == nil && u != "" {
		for _, l := range strings.Split(u, "\n") {
			if f := strings.Fields(l); len(f) > 0 {
				res.Running = append(res.Running, f[0])
			}
		}
	}
	res.Disk = diskUsage(data)
	res.CPUPct = cpuUsage()
	writeJSON(w, res)
}

// diskInfo is the parsed, labeled disk usage for the filesystem holding `data`.
type diskInfo struct {
	Size  string `json:"size"`  // total, human-readable (e.g. "32G")
	Used  string `json:"used"`  // used (e.g. "11G")
	Avail string `json:"avail"` // free (e.g. "22G")
	Pct   int    `json:"pct"`   // percent used (0-100)
}

// diskUsage runs df on the given path and returns its usage as labeled fields.
// --output pins the columns so parsing doesn't depend on device/mount naming.
func diskUsage(path string) diskInfo {
	var di diskInfo
	out, err := run("df", "-h", "--output=size,used,avail,pcent", path)
	if err != nil {
		return di
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 2 {
		return di
	}
	f := strings.Fields(lines[len(lines)-1])
	if len(f) < 4 {
		return di
	}
	di.Size, di.Used, di.Avail = f[0], f[1], f[2]
	di.Pct, _ = strconv.Atoi(strings.TrimSuffix(f[3], "%"))
	return di
}

// cpuUsage returns busy CPU percent (0-100) for the container, measured as the
// delta between the two most recent samples of /proc/stat. Under lxcfs (Proxmox
// LXC) /proc/stat is container-scoped, so this reflects the container's own load.
// The first call after startup has no prior sample and returns 0.
var cpuPrev struct {
	sync.Mutex
	total, idle uint64
	seen        bool
}

func cpuUsage() int {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0
	}
	line := b
	if i := strings.IndexByte(string(b), '\n'); i >= 0 {
		line = b[:i]
	}
	f := strings.Fields(string(line))
	if len(f) < 5 || f[0] != "cpu" {
		return 0
	}
	var total, idle uint64
	for i := 1; i < len(f); i++ {
		v, _ := strconv.ParseUint(f[i], 10, 64)
		total += v
		if i == 4 || i == 5 { // idle + iowait
			idle += v
		}
	}
	cpuPrev.Lock()
	defer cpuPrev.Unlock()
	prevTotal, prevIdle, seen := cpuPrev.total, cpuPrev.idle, cpuPrev.seen
	cpuPrev.total, cpuPrev.idle, cpuPrev.seen = total, idle, true
	if !seen || total <= prevTotal {
		return 0
	}
	dt := total - prevTotal
	di := idle - prevIdle
	pct := int((dt - di) * 100 / dt)
	if pct < 0 {
		pct = 0
	} else if pct > 100 {
		pct = 100
	}
	return pct
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// ---- build + logs ----------------------------------------------------------

func hBuild(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Arch  string `json:"arch"`
		Group string `json:"group"`
		Pkg   string `json:"pkg"`
		Force bool   `json:"force"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil || !archExists(req.Arch) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	args := []string{req.Arch}
	if req.Pkg != "" {
		if !nameRe.MatchString(req.Pkg) {
			httpErr(w, http.StatusBadRequest, "bad pkg")
			return
		}
		args = append(args, "--pkg", req.Pkg)
	} else if req.Group != "" {
		if !nameRe.MatchString(req.Group) {
			httpErr(w, http.StatusBadRequest, "bad group")
			return
		}
		args = append(args, "--group", req.Group)
	}
	if req.Force {
		args = append(args, "--force")
	}
	unit := fmt.Sprintf("pkgmirror-adhoc-%d", time.Now().UnixNano())
	sysArgs := []string{"systemd-run", "--unit=" + unit, "--uid=pkgmirror",
		"--setenv=PKGMIRROR_DATA=" + data, "--setenv=PKGMIRROR_UNIT=" + unit,
		"--property=WorkingDirectory=" + root,
		"bash", filepath.Join(root, "bin/build.sh")}
	sysArgs = append(sysArgs, args...)
	if out, err := run("sudo", sysArgs...); err != nil {
		httpErr(w, http.StatusInternalServerError, "systemd-run failed: "+out)
		return
	}
	writeJSON(w, map[string]string{"unit": unit})
}

// hLogStream streams a unit's journal to the client as SSE, ending when the unit
// is no longer active.
func hLogStream(w http.ResponseWriter, r *http.Request) {
	unit := r.URL.Query().Get("unit")
	if !unitRe.MatchString(unit) {
		httpErr(w, http.StatusBadRequest, "bad unit")
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		httpErr(w, http.StatusInternalServerError, "no flush")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	cmd := exec.CommandContext(ctx, "sudo", "journalctl", "-o", "cat", "-n", "500", "-f", "-u", unit)
	stdout, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		httpErr(w, http.StatusInternalServerError, "journalctl failed")
		return
	}

	// Watchdog: once the unit goes inactive, give journalctl a moment to drain,
	// then stop the stream.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
				st, _ := run("systemctl", "is-active", unit)
				if st != "active" && st != "activating" {
					time.Sleep(1500 * time.Millisecond)
					cancel()
					return
				}
			}
		}
	}()

	buf := make([]byte, 4096)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			for _, line := range strings.Split(string(buf[:n]), "\n") {
				fmt.Fprintf(w, "data: %s\n\n", line)
			}
			fl.Flush()
		}
		if err != nil {
			break
		}
	}
	fmt.Fprintf(w, "event: done\ndata: end\n\n")
	fl.Flush()
	cmd.Wait()
}

func hBuilds(w http.ResponseWriter, r *http.Request) {
	a := r.PathValue("arch")
	if !archExists(a) {
		httpErr(w, http.StatusBadRequest, "bad arch")
		return
	}
	b, _ := os.ReadFile(filepath.Join(data, "state", a, "history.jsonl"))
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	// newest last -> reverse, cap 50
	var out []json.RawMessage
	for i := len(lines) - 1; i >= 0 && len(out) < 50; i-- {
		if strings.TrimSpace(lines[i]) != "" {
			out = append(out, json.RawMessage(lines[i]))
		}
	}
	writeJSON(w, out)
}

// scanHistory streams the build-sweep records in one arch's history.jsonl,
// calling fn for each with its parsed end time (falling back to start) and the
// raw line. Used by the merged builds feed and per-package history.
func scanHistory(arch string, fn func(end int64, raw []byte)) {
	fh, err := os.Open(filepath.Join(data, "state", arch, "history.jsonl"))
	if err != nil {
		return
	}
	defer fh.Close()
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var t struct {
			Start int64 `json:"start"`
			End   int64 `json:"end"`
		}
		if json.Unmarshal(line, &t) != nil {
			continue
		}
		end := t.End
		if end == 0 {
			end = t.Start
		}
		// copy: Scanner reuses its buffer across iterations
		fn(end, append([]byte(nil), line...))
	}
}

// hAllBuilds serves a newest-first, paged feed of build sweeps merged across all
// arches. Query: page (1-based, default 1), per (default 25, max 200).
func hAllBuilds(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	if page < 1 {
		page = 1
	}
	per, _ := strconv.Atoi(r.URL.Query().Get("per"))
	if per < 1 {
		per = 25
	} else if per > 200 {
		per = 200
	}
	type rec struct {
		end int64
		raw json.RawMessage
	}
	var all []rec
	for _, a := range arches() {
		scanHistory(a, func(end int64, raw []byte) {
			all = append(all, rec{end, json.RawMessage(raw)})
		})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].end > all[j].end })
	total := len(all)
	start := (page - 1) * per
	if start > total {
		start = total
	}
	end := start + per
	if end > total {
		end = total
	}
	builds := make([]json.RawMessage, 0, end-start)
	for _, r := range all[start:end] {
		builds = append(builds, r.raw)
	}
	writeJSON(w, map[string]any{"total": total, "page": page, "per": per, "builds": builds})
}

// hPkgHistory returns every build attempt for one package in one arch (newest
// first), each carrying the package's own start epoch — which keys its saved log.
func hPkgHistory(w http.ResponseWriter, r *http.Request) {
	a, pkg := r.PathValue("arch"), r.PathValue("pkg")
	if !archExists(a) || !nameRe.MatchString(pkg) {
		httpErr(w, http.StatusBadRequest, "bad arch/pkg")
		return
	}
	type attempt struct {
		SweepStart int64  `json:"sweep_start"`
		SweepEnd   int64  `json:"sweep_end"`
		Filter     string `json:"filter"`
		Result     string `json:"result"`
		Version    string `json:"version"`
		Seconds    int64  `json:"seconds"`
		Start      int64  `json:"start"` // per-package start; keys logs/<pkg>/<start>.log
		HasLog     bool   `json:"has_log"`
	}
	var out []attempt
	scanHistory(a, func(_ int64, raw []byte) {
		var rec struct {
			Start    int64  `json:"start"`
			End      int64  `json:"end"`
			Filter   string `json:"filter"`
			Packages []struct {
				Name    string `json:"name"`
				Result  string `json:"result"`
				Version string `json:"version"`
				Seconds int64  `json:"seconds"`
				PStart  int64  `json:"start"`
			} `json:"packages"`
		}
		if json.Unmarshal(raw, &rec) != nil {
			return
		}
		for _, p := range rec.Packages {
			if p.Name != pkg {
				continue
			}
			at := attempt{SweepStart: rec.Start, SweepEnd: rec.End, Filter: rec.Filter,
				Result: p.Result, Version: p.Version, Seconds: p.Seconds, Start: p.PStart}
			if p.PStart > 0 {
				if _, err := os.Stat(filepath.Join(data, "state", a, "logs", pkg,
					strconv.FormatInt(p.PStart, 10)+".log")); err == nil {
					at.HasLog = true
				}
			}
			out = append(out, at)
		}
	})
	// newest first
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	writeJSON(w, out)
}

// hBuildLog serves a persisted per-package build log (logs/<pkg>/<ts>.log).
func hBuildLog(w http.ResponseWriter, r *http.Request) {
	a, pkg, ts := r.PathValue("arch"), r.PathValue("pkg"), r.PathValue("ts")
	if !archExists(a) || !nameRe.MatchString(pkg) || !isDigits(ts) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	b, err := os.ReadFile(filepath.Join(data, "state", a, "logs", pkg, ts+".log"))
	if err != nil {
		httpErr(w, http.StatusNotFound, "no log for this build")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write(b)
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// ---- package management ----------------------------------------------------

func hAddPackage(w http.ResponseWriter, r *http.Request) {
	a := r.PathValue("arch")
	if !archExists(a) {
		httpErr(w, http.StatusBadRequest, "bad arch")
		return
	}
	var req struct{ Name, Tier, Source string }
	if json.NewDecoder(r.Body).Decode(&req) != nil || !nameRe.MatchString(req.Name) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	args := []string{filepath.Join(root, "bin/add-package.sh"), a, req.Name}
	if req.Tier != "" {
		args = append(args, "--tier", req.Tier)
	}
	if req.Source != "" {
		args = append(args, "--source", req.Source)
	}
	if out, err := run("bash", args...); err != nil {
		httpErr(w, http.StatusInternalServerError, out)
		return
	}
	writeJSON(w, map[string]string{"ok": "1"})
}

func hRemovePackage(w http.ResponseWriter, r *http.Request) {
	a, p := r.PathValue("arch"), r.PathValue("pkg")
	if !archExists(a) || !nameRe.MatchString(p) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	if out, err := run("bash", filepath.Join(root, "bin/remove-package.sh"), a, p); err != nil {
		httpErr(w, http.StatusInternalServerError, out)
		return
	}
	writeJSON(w, map[string]string{"ok": "1"})
}

// ---- PKGBUILD read/write ---------------------------------------------------

func pkgbuildPath(a, p string) (string, bool) {
	if !archExists(a) || !nameRe.MatchString(p) {
		return "", false
	}
	return filepath.Join(root, "pkgbuilds", a, p, "PKGBUILD"), true
}

func hGetPkgbuild(w http.ResponseWriter, r *http.Request) {
	path, ok := pkgbuildPath(r.PathValue("arch"), r.PathValue("pkg"))
	if !ok {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	b, err := os.ReadFile(path)
	if err != nil {
		b = []byte("")
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write(b)
}

func hPutPkgbuild(w http.ResponseWriter, r *http.Request) {
	path, ok := pkgbuildPath(r.PathValue("arch"), r.PathValue("pkg"))
	if !ok {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	body := make([]byte, 0, 1<<16)
	buf := make([]byte, 4096)
	for {
		n, err := r.Body.Read(buf)
		body = append(body, buf[:n]...)
		if err != nil {
			break
		}
		if len(body) > 1<<20 {
			httpErr(w, http.StatusRequestEntityTooLarge, "too big")
			return
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		httpErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, map[string]string{"ok": "1"})
}

// ---- chroot bootstrap + update-check ---------------------------------------

func hBootstrap(w http.ResponseWriter, r *http.Request) {
	a := r.PathValue("arch")
	if !archExists(a) {
		httpErr(w, http.StatusBadRequest, "bad arch")
		return
	}
	unit := fmt.Sprintf("pkgmirror-adhoc-%d", time.Now().UnixNano())
	out, err := run("sudo", "systemd-run", "--unit="+unit,
		"--setenv=REPO_ROOT="+root, "--property=WorkingDirectory="+root,
		"bash", filepath.Join(root, "installer/bootstrap-chroot.sh"), a)
	if err != nil {
		httpErr(w, http.StatusInternalServerError, "systemd-run failed: "+out)
		return
	}
	writeJSON(w, map[string]string{"unit": unit})
}

func hUpdateCheck(w http.ResponseWriter, r *http.Request) {
	a := r.PathValue("arch")
	if !archExists(a) {
		httpErr(w, http.StatusBadRequest, "bad arch")
		return
	}
	out, _ := run("bash", filepath.Join(root, "bin/update-check.sh"), a)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte(out))
}

// ---- groups + arch subscriptions -------------------------------------------

func groupSh(w http.ResponseWriter, args ...string) {
	if out, err := run("bash", append([]string{filepath.Join(root, "bin/group.sh")}, args...)...); err != nil {
		httpErr(w, http.StatusInternalServerError, out)
		return
	}
	writeJSON(w, map[string]string{"ok": "1"})
}

func hCreateGroup(w http.ResponseWriter, r *http.Request) {
	var req struct{ Name, Description string }
	if json.NewDecoder(r.Body).Decode(&req) != nil || !nameRe.MatchString(req.Name) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	groupSh(w, "create", req.Name, "--desc", req.Description)
}

func hGroupAdd(w http.ResponseWriter, r *http.Request) {
	g, p := r.PathValue("group"), r.PathValue("pkg")
	if !nameRe.MatchString(g) || !nameRe.MatchString(p) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	groupSh(w, "add", g, p)
}

func hGroupRemove(w http.ResponseWriter, r *http.Request) {
	g, p := r.PathValue("group"), r.PathValue("pkg")
	if !nameRe.MatchString(g) || !nameRe.MatchString(p) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	groupSh(w, "remove", g, p)
}

func hArchGroupEnable(w http.ResponseWriter, r *http.Request) {
	a, g := r.PathValue("arch"), r.PathValue("group")
	if !archExists(a) || !nameRe.MatchString(g) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	groupSh(w, "enable", a, g)
}

func hArchGroupDisable(w http.ResponseWriter, r *http.Request) {
	a, g := r.PathValue("arch"), r.PathValue("group")
	if !archExists(a) || !nameRe.MatchString(g) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	groupSh(w, "disable", a, g)
}

// ---- pause / resume / stop -------------------------------------------------

func hControl(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if out, err := run("bash", filepath.Join(root, "bin/control.sh"), action); err != nil {
			httpErr(w, http.StatusInternalServerError, out)
			return
		}
		writeJSON(w, map[string]string{"ok": "1"})
	}
}
