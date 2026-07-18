// pkgmirror-web — monitoring & operations UI for the pkgmirror build box.
//
// Reads config natively via internal/pkgconfig (no per-field dasel subprocess
// spawns), reads build state files, queries systemd/journald, and shells out
// to the existing bin/*.sh scripts for mutations (add/remove package, set
// override, group/arch edits). Bash remains the single source of truth for
// build *logic* (bin/build.sh's orchestration is untouched); config *reads*
// are native Go. Runs as the `pkgmirror` user (which has full NOPASSWD sudo)
// behind nginx; no auth (LAN trust).
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
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"pkgmirror/web/internal/pkgconfig"
)

//go:embed static
var staticFS embed.FS

// appVersion is bumped by hand alongside each git tag (see README's release
// process) -- this project has no CI-driven ldflags version injection, so
// this constant is the single source of truth the UI's footer reads from.
const appVersion = "v1.1.2"

var (
	root    = env("PKGMIRROR_ROOT", "/opt/pkgmirror")
	data    = env("PKGMIRROR_DATA", "/srv/pkgmirror")
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
	mux.HandleFunc("GET /api/logs/build/{arch}/{pkg}/{ts}/stream", hBuildLogStream)
	mux.HandleFunc("GET /api/builds", hAllBuilds)
	mux.HandleFunc("GET /api/builds/{arch}", hBuilds)
	mux.HandleFunc("GET /api/history/{arch}/{pkg}", hPkgHistory)
	mux.HandleFunc("POST /api/packages/{arch}", hAddPackage)
	mux.HandleFunc("DELETE /api/packages/{arch}/{pkg}", hRemovePackage)
	mux.HandleFunc("GET /api/pkgbuild/{arch}/{pkg}", hGetPkgbuild)
	mux.HandleFunc("PUT /api/pkgbuild/{arch}/{pkg}", hPutPkgbuild)
	mux.HandleFunc("GET /api/override/{arch}/{pkg}", hGetOverride)
	mux.HandleFunc("PUT /api/override/{arch}/{pkg}", hPutOverride)
	mux.HandleFunc("GET /api/pkgsearch", hPkgSearch)
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
	mux.HandleFunc("POST /api/build/{arch}/cancel", hCancelBuild)

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

func archConf(a string) string { return filepath.Join(root, "config/arches", a+".toml") }
func pkgList(a string) string  { return filepath.Join(root, "config/packages", a+".toml") }

// archStatic returns an arch's base/cflags/groups fields. Previously cached
// (keyed by config file mtime) to paper over 3 dasel subprocess spawns per
// arch per /api/status poll; native TOML parsing of one small file is
// sub-millisecond, so the cache isn't needed anymore — this is now a direct
// pkgconfig.LoadArch call every time.
func archStatic(a string) (base, cflags string, groups []string) {
	ac, err := pkgconfig.LoadArch(root, a)
	if err != nil {
		return "", "", nil
	}
	return ac.Base, ac.CFlags, ac.Groups
}

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
// repoVersion returns the version of the newest built package in arch's repo,
// or "" if absent. The glob requires a digit right after "<pkg>-" -- pacman
// filenames are <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst and pkgver
// conventionally starts with a digit -- so a split package's siblings that
// merely share the name prefix (freetype2-docs, freetype2-demos,
// freetype2-debug) don't get mistaken for freetype2 itself. Mirrors
// bin/lib/common.sh's repo_version (same bug, same fix, kept in sync).
func repoVersion(arch, pkg string) string {
	files, _ := filepath.Glob(filepath.Join(data, "repos", arch, pkg+"-[0-9]*.pkg.tar.zst"))
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

// pkgbuildVersion sources a PKGBUILD in bash and returns "[epoch:]pkgver-pkgrel"
// (or ""), matching pacman's real filename convention -- mirrors
// bin/lib/common.sh's pkgbuild_version (same epoch-dropping bug, same fix,
// kept in sync). Without the epoch, a package with one set would never match
// repoVersion's parse of the actual built filename, so the UI's DUE badge
// would show it as perpetually out of date even when it wasn't.
func pkgbuildVersion(dir string) string {
	if _, err := os.Stat(filepath.Join(dir, "PKGBUILD")); err != nil {
		return ""
	}
	out, err := run("bash", "-c",
		`set +eu; source "$1/PKGBUILD" >/dev/null 2>&1
		if [ -n "${epoch:-}" ] && [ "$epoch" != 0 ]; then
			printf '%s:%s-%s' "$epoch" "${pkgver:-}" "${pkgrel:-}"
		else
			printf '%s-%s' "${pkgver:-}" "${pkgrel:-}"
		fi`,
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
	// Per-package build override (config/overrides/<arch>.toml + hooks/), if any.
	HasOverride     bool   `json:"has_override,omitempty"`
	OverrideSummary string `json:"override_summary,omitempty"`
	// source=git only: the repo/ref this package is cloned from.
	GitURL string `json:"git_url,omitempty"`
	GitRef string `json:"git_ref,omitempty"`
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

// packagesFor mirrors bin/lib/common.sh's effective_packages (see
// pkgconfig.EffectivePackages, which reimplements it field-for-field) —
// previously a re-entrant `bash -c 'source common.sh; effective_packages ...'`
// shell-out, now native.
func packagesFor(arch string) []pkgInfo {
	eff, err := pkgconfig.EffectivePackages(root, arch)
	if err != nil {
		return nil
	}
	stats := buildStats(arch)
	overrides := overridesFor(arch)
	giturls := giturlsFor(arch)
	var pkgs []pkgInfo
	for _, e := range eff {
		p := pkgInfo{Name: e.Name, Source: e.Source, Origin: e.Origin, RepoVer: repoVersion(arch, e.Name)}
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
		p.HasOverride, p.OverrideSummary = overrideSummary(overrides[p.Name], localDir)
		if g, ok := giturls[p.Name]; ok {
			p.GitURL, p.GitRef = g[0], g[1]
		}
		pkgs = append(pkgs, p)
	}
	return pkgs
}

// overrideInfo mirrors bin/lib/common.sh pkg_override's fields; MakepkgArgs/
// Patches are comma-joined here (rather than kept as []string) purely so
// overrideSummary's existing `!= ""` checks and rendering don't need to change.
type overrideInfo struct {
	Pin, SkipCheck, MakepkgArgsCSV, PatchesCSV, MemPerJobMB, Notes string
}

// overridesFor reads every override entry for arch, natively — previously a
// `bash -c 'source common.sh; overrides_all ...'` shell-out.
func overridesFor(arch string) map[string]overrideInfo {
	m := map[string]overrideInfo{}
	overrides, err := pkgconfig.LoadOverrides(root, arch)
	if err != nil {
		return m
	}
	for _, o := range overrides {
		if o.Name == "" {
			continue
		}
		m[o.Name] = overrideInfo{
			Pin: o.Pin, SkipCheck: string(o.SkipCheck),
			MakepkgArgsCSV: strings.Join(o.MakepkgArgs, ","),
			PatchesCSV:     strings.Join(o.Patches, ","),
			MemPerJobMB:    string(o.MemPerJobMB), Notes: o.Notes,
		}
	}
	return m
}

// giturlsFor reads every source=git package's url/ref for arch, natively —
// previously a `bash -c 'source common.sh; pkg_giturls_all ...'` shell-out.
// Value is [2]string{url, ref}.
func giturlsFor(arch string) map[string][2]string {
	m := map[string][2]string{}
	pkgs, err := pkgconfig.LoadPackages(root, arch)
	if err != nil {
		return m
	}
	for _, p := range pkgs {
		if p.Name == "" || p.Source != "git" {
			continue
		}
		m[p.Name] = [2]string{p.URL, p.Ref}
	}
	return m
}

// overrideSummary renders an overrideInfo (plus a hooks/post_fetch.sh check, which
// is file-based and not part of the TOML entry) into the package row's badge.
func overrideSummary(ov overrideInfo, localDir string) (bool, string) {
	var parts []string
	if ov.Pin != "" {
		parts = append(parts, "pinned")
	}
	if ov.PatchesCSV != "" {
		parts = append(parts, "patched")
	}
	if ov.SkipCheck != "" {
		parts = append(parts, "skip-check="+ov.SkipCheck)
	}
	if ov.MakepkgArgsCSV != "" {
		parts = append(parts, "extra-args")
	}
	if ov.MemPerJobMB != "" {
		parts = append(parts, "mem="+ov.MemPerJobMB+"MB")
	}
	if fi, err := os.Stat(filepath.Join(localDir, "hooks", "post_fetch.sh")); err == nil && !fi.IsDir() {
		parts = append(parts, "hook")
	}
	if len(parts) == 0 {
		return false, ""
	}
	return true, strings.Join(parts, ", ")
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

func groupsAll() []groupInfo {
	var out []groupInfo
	for _, name := range pkgconfig.GroupNames(root) {
		g, err := pkgconfig.LoadGroup(root, name)
		if err != nil {
			continue
		}
		out = append(out, groupInfo{Name: name, Description: g.Description, Packages: g.Packages})
	}
	return out
}

func hStatus(w http.ResponseWriter, r *http.Request) {
	type resp struct {
		Arches      []archInfo      `json:"arches"`
		Groups      []groupInfo     `json:"groups"`
		Paused      bool            `json:"paused"`
		Running     []string        `json:"running"`
		Disk        diskInfo        `json:"disk"`
		CPUPct      int             `json:"cpuPct"`
		Mem         memInfo         `json:"mem"`
		ChrootTmpfs []archTmpfsInfo `json:"chrootTmpfs"`
		Version     string          `json:"version"`
		Now         int64           `json:"now"`
	}
	var res resp
	res.Now = time.Now().Unix()
	res.Groups = groupsAll()
	res.Paused = fileExists(filepath.Join(data, "state", "paused"))
	// Each arch's status is ~4-5 independent subprocess spawns (dasel/bash/
	// systemctl); computing them sequentially sums their latency, which under
	// concurrent build load (compilers contending for CPU scheduling) can push a
	// single /api/status call to several seconds. Run arches concurrently so
	// wall-clock time is bounded by the slowest arch, not the sum of all of
	// them — same total CPU work, just not serialized into one request.
	archList := arches()
	res.Arches = make([]archInfo, len(archList))
	var wg sync.WaitGroup
	for i, a := range archList {
		wg.Add(1)
		go func(i int, a string) {
			defer wg.Done()
			base, cflags, groups := archStatic(a)
			ai := archInfo{
				Name:          a,
				Base:          base,
				CFlags:        cflags,
				ChrootReady:   fileExists(filepath.Join(data, "chroots", a, "root", ".pkgmirror-ready")),
				EnabledGroups: groups,
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
			res.Arches[i] = ai
		}(i, a)
	}
	wg.Wait()
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
	res.Mem = memUsage()
	res.ChrootTmpfs = chrootTmpfsUsage(archList)
	res.Version = appVersion
	writeJSON(w, res)
}

// memInfo is the container's RAM usage (lxcfs makes /proc/meminfo container-scoped).
type memInfo struct {
	Total string `json:"total"` // human-readable (e.g. "3.9G")
	Used  string `json:"used"`  // total - available
	Avail string `json:"avail"` // MemAvailable
	Pct   int    `json:"pct"`   // percent used (0-100)
}

// memUsage reads /proc/meminfo and returns used/available RAM. "Used" is derived
// from MemAvailable (the kernel's estimate of allocatable memory), which reflects
// real pressure better than MemFree.
func memUsage() memInfo {
	var mi memInfo
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return mi
	}
	var totalKB, availKB uint64
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		v, _ := strconv.ParseUint(f[1], 10, 64) // value is in kB
		switch f[0] {
		case "MemTotal:":
			totalKB = v
		case "MemAvailable:":
			availKB = v
		}
	}
	if totalKB == 0 {
		return mi
	}
	usedKB := totalKB - availKB
	mi.Total, mi.Used, mi.Avail = humKB(totalKB), humKB(usedKB), humKB(availKB)
	mi.Pct = int(usedKB * 100 / totalKB)
	return mi
}

// humKB renders a kB count as a compact human-readable size (G with one decimal,
// or M for sub-gigabyte values).
func humKB(kb uint64) string {
	if kb >= 1024*1024 {
		return strconv.FormatFloat(float64(kb)/(1024*1024), 'f', 1, 64) + "G"
	}
	return strconv.FormatUint(kb/1024, 10) + "M"
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

// archTmpfsInfo is one arch's build-copy tmpfs usage.
type archTmpfsInfo struct {
	Arch string `json:"arch"`
	diskInfo
}

// chrootTmpfsUsage returns each arch's build-copy tmpfs usage (see
// installer/bootstrap-chroot.sh's chroots/<arch>/pkgmirror mount) -- the
// resource that caused a real container-wide OOM (2026-07-18, linux-btver1):
// makechrootpkg's -c cleans a copy right before its NEXT use, so a copy left
// dirty by a failure sits full, unreclaimed, until then. bin/clean-chroots.sh
// now reclaims it explicitly (at every sweep's start/end and on a timer);
// this surfaces the same numbers so an operator can see it building up
// between reclaims, not just after the fact in a build log.
func chrootTmpfsUsage(archList []string) []archTmpfsInfo {
	out := make([]archTmpfsInfo, 0, len(archList))
	for _, a := range archList {
		di := diskUsage(filepath.Join(data, "chroots", a, "pkgmirror"))
		if di.Size == "" {
			continue // not bootstrapped yet -- the tmpfs doesn't exist
		}
		out = append(out, archTmpfsInfo{Arch: a, diskInfo: di})
	}
	return out
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

// hBuildLogStream tails a persisted per-package build log (logs/<pkg>/<ts>.log)
// as SSE, replacing the old fixed-interval full-file re-fetch the dashboard used
// to do for the "log so far" live view (the build console already streamed via
// hLogStream/journalctl -f -u <unit>, but a unit covers the whole sweep — every
// package interleaved — so it can't serve one package's own log; this mirrors
// hLogStream's structure against the file instead). Termination is signaled by
// state/<arch>/progress/<pkg> (written by build.sh's run_pkg as "status\tepoch")
// leaving "building", since there's no systemd unit scoped to a single package.
func hBuildLogStream(w http.ResponseWriter, r *http.Request) {
	a, pkg, ts := r.PathValue("arch"), r.PathValue("pkg"), r.PathValue("ts")
	if !archExists(a) || !nameRe.MatchString(pkg) || !isDigits(ts) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	logPath := filepath.Join(data, "state", a, "logs", pkg, ts+".log")
	progressPath := filepath.Join(data, "state", a, "progress", pkg)

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

	// -F (retry + follow-by-name) rather than -f: the log file may not exist
	// yet the instant a build starts and the client races to open the stream.
	cmd := exec.CommandContext(ctx, "tail", "-n", "+1", "-F", logPath)
	stdout, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		httpErr(w, http.StatusInternalServerError, "tail failed")
		return
	}

	// Watchdog: once progress/<pkg> no longer says "building" (or is gone —
	// clear_current removes the whole progress dir at sweep end), give tail a
	// moment to drain, then stop the stream. Same shape as hLogStream's
	// systemctl-polling watchdog, just keyed off the progress file instead.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
				b, err := os.ReadFile(progressPath)
				status := ""
				if err == nil {
					if i := strings.IndexByte(string(b), '\t'); i >= 0 {
						status = string(b)[:i]
					}
				}
				if status != "building" {
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
	var req struct{ Name, Tier, Source, Url, Ref string }
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
	if req.Source == "git" {
		args = append(args, "--url", req.Url)
		if req.Ref != "" {
			args = append(args, "--ref", req.Ref)
		}
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

// ---- per-package overrides --------------------------------------------------

// hGetOverride returns one package's override fields (empty strings/nil slices
// if it has none) — GET counterpart used to pre-fill the edit modal.
func hGetOverride(w http.ResponseWriter, r *http.Request) {
	a, p := r.PathValue("arch"), r.PathValue("pkg")
	if !archExists(a) || !nameRe.MatchString(p) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	resp := struct {
		Pin         string   `json:"pin"`
		SkipCheck   string   `json:"skip_check"` // "" | "true" | "false"
		MakepkgArgs []string `json:"makepkg_args"`
		Patches     []string `json:"patches"`
		MemPerJobMB string   `json:"mem_per_job_mb"`
		Notes       string   `json:"notes"`
		HasHook     bool     `json:"has_hook"`
	}{}
	if o, ok := pkgconfig.OverrideFor(root, a, p); ok {
		resp.Pin, resp.SkipCheck, resp.MemPerJobMB, resp.Notes = o.Pin, string(o.SkipCheck), string(o.MemPerJobMB), o.Notes
		resp.MakepkgArgs, resp.Patches = o.MakepkgArgs, o.Patches
	}
	if fi, err := os.Stat(filepath.Join(root, "pkgbuilds", a, p, "hooks", "post_fetch.sh")); err == nil && !fi.IsDir() {
		resp.HasHook = true
	}
	writeJSON(w, resp)
}

// hPutOverride sets (or, with Clear, removes) a package's override entry by
// shelling to bin/override.sh — same pattern as hAddPackage -> add-package.sh.
// Fields omitted from the request body are left untouched on an existing entry
// (bin/override.sh only overwrites flags actually passed); skip_check/
// mem_per_job_mb are only forwarded when non-empty, since the CLI validates them.
func hPutOverride(w http.ResponseWriter, r *http.Request) {
	a, p := r.PathValue("arch"), r.PathValue("pkg")
	if !archExists(a) || !nameRe.MatchString(p) {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	var req struct {
		Pin         string   `json:"pin"`
		SkipCheck   string   `json:"skip_check"`
		MakepkgArgs []string `json:"makepkg_args"`
		Patches     []string `json:"patches"`
		MemPerJobMB string   `json:"mem_per_job_mb"`
		Notes       string   `json:"notes"`
		Clear       bool     `json:"clear"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		httpErr(w, http.StatusBadRequest, "bad request")
		return
	}
	args := []string{filepath.Join(root, "bin/override.sh"), a, p}
	if req.Clear {
		args = append(args, "--clear")
	} else {
		args = append(args, "--pin", req.Pin,
			"--makepkg-args", strings.Join(req.MakepkgArgs, ","),
			"--patches", strings.Join(req.Patches, ","),
			"--notes", req.Notes)
		if req.SkipCheck == "true" || req.SkipCheck == "false" {
			args = append(args, "--skip-check", req.SkipCheck)
		}
		if req.MemPerJobMB != "" {
			args = append(args, "--mem-per-job-mb", req.MemPerJobMB)
		}
	}
	if out, err := run("bash", args...); err != nil {
		httpErr(w, http.StatusInternalServerError, out)
		return
	}
	writeJSON(w, map[string]string{"ok": "1"})
}

// ---- package search (add-to-group/extra autocomplete) ----------------------

type pkgSearchResult struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	Repo        string `json:"repo"` // core | extra | aur
	Description string `json:"description"`
}

var pacmanSsRe = regexp.MustCompile(`^(?:\S+/)?(core|extra|community|multilib)/(\S+)\s+(\S+)`)

// hPkgSearch answers "does this package exist, and where" for the add-to-group /
// add-extra-package autocomplete. No arch param: groups are arch-agnostic, and
// this is existence/provenance lookup, not a per-chroot buildability check.
func hPkgSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" || len(q) > 64 {
		writeJSON(w, []pkgSearchResult{})
		return
	}
	var results []pkgSearchResult
	if out, err := run("pacman", "-Ss", q); err == nil {
		lines := strings.Split(out, "\n")
		for i := 0; i < len(lines) && len(results) < 10; i++ {
			m := pacmanSsRe.FindStringSubmatch(lines[i])
			if m == nil {
				continue
			}
			desc := ""
			// pacman -Ss prints the description on the next (indented) line.
			if i+1 < len(lines) && strings.HasPrefix(lines[i+1], "    ") {
				desc = strings.TrimSpace(lines[i+1])
			}
			results = append(results, pkgSearchResult{Name: m[2], Version: m[3], Repo: m[1], Description: desc})
		}
	}
	if aur, err := aurSearch(q); err == nil {
		results = append(results, aur...)
	}
	writeJSON(w, results)
}

// aurSearch queries AUR's public RPC v5 search endpoint (by=name-desc, matching
// how AUR helpers default), capped to 10 results.
func aurSearch(q string) ([]pkgSearchResult, error) {
	u := "https://aur.archlinux.org/rpc/v5/search/" + url.PathEscape(q) + "?by=name-desc"
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var parsed struct {
		Results []struct {
			Name        string `json:"Name"`
			Version     string `json:"Version"`
			Description string `json:"Description"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, err
	}
	var out []pkgSearchResult
	for i, r := range parsed.Results {
		if i >= 10 {
			break
		}
		out = append(out, pkgSearchResult{Name: r.Name, Version: r.Version, Repo: "aur", Description: r.Description})
	}
	return out, nil
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

// hCancelBuild stops only the named arch's running build (scheduled unit and/or
// whichever ad-hoc unit is currently building it), leaving other arches'
// in-flight builds untouched — unlike /api/stop, which stops everything.
func hCancelBuild(w http.ResponseWriter, r *http.Request) {
	a := r.PathValue("arch")
	if !archExists(a) {
		httpErr(w, http.StatusBadRequest, "bad arch")
		return
	}
	if out, err := run("bash", filepath.Join(root, "bin/control.sh"), "stop-arch", a); err != nil {
		httpErr(w, http.StatusInternalServerError, out)
		return
	}
	writeJSON(w, map[string]string{"ok": "1"})
}
