// Package pkgconfig reads pkgmirror's config/*.toml files natively in Go,
// replacing web/main.go's per-field `dasel` subprocess spawns and its
// re-entrant `bash -c 'source common.sh; effective_packages ...'` shell-out.
//
// Read-only by design: config/arches/*.toml and config/groups/*.toml carry
// real hand-written `#`-comments (operational notes), and no mature Go TOML
// library preserves comments through a typed struct marshal. Writing those
// files stays on the existing dasel-based path (bin/group.sh, bin/add-arch.sh).
// config/packages/*.toml and config/overrides/*.toml have zero `#`-comments
// (verified) so they'd be safe to write natively too, but that's not needed
// here — bin/add-package.sh/remove-package.sh/override.sh still own writes.
//
// EffectivePackages and the Override lookups mirror bin/lib/common.sh's
// effective_packages/pkg_records/overrides_all functions field-for-field;
// keep them in sync if that bash logic changes.
package pkgconfig

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/pelletier/go-toml/v2"
)

// Arch mirrors config/arches/<name>.toml.
type Arch struct {
	Name      string   `toml:"name"`
	Base      string   `toml:"base"`
	Toolchain string   `toml:"toolchain"`
	CFlags    string   `toml:"cflags"`
	Groups    []string `toml:"groups"`
	Chroot    struct {
		Mirror  string `toml:"mirror"`
		Keyring string `toml:"keyring"`
	} `toml:"chroot"`
}

// Package mirrors one [[package]] entry in config/packages/<arch>.toml — a
// per-arch extra (WHAT gets built beyond the arch's enabled groups).
type Package struct {
	Name   string `toml:"name"`
	Source string `toml:"source"` // upstream|local|aur|git, may be empty
	URL    string `toml:"url"`    // source=git only
	Ref    string `toml:"ref"`    // source=git only, empty = default branch
}

type packagesFile struct {
	Package []Package `toml:"package"`
}

// Group mirrors config/groups/<name>.toml.
type Group struct {
	Name        string   `toml:"name"`
	Description string   `toml:"description"`
	Packages    []string `toml:"packages"`
}

// Override mirrors one [[override]] entry in config/overrides/<arch>.toml —
// HOW a package builds, independent of WHAT gets built. Never unmarshaled
// directly (see rawOverride) — this is the public, already-stringified shape.
type Override struct {
	Name        string
	Pin         string
	SkipCheck   string
	MakepkgArgs []string
	Patches     []string
	MemPerJobMB string
	Notes       string
}

// rawOverride is Override's on-disk shape. config/overrides/*.toml stores
// skip_check as a real bool and mem_per_job_mb as a real int (bin/override.sh:
// `dasel put -t bool`/`-t int`), but the rest of this codebase (bin/lib/
// common.sh's toml_get, and this package's own consumers like
// overrideSummary) has always treated every override field as plain text —
// dasel's scalar reads return text regardless of the underlying TOML type. A
// plain `string` struct field can't unmarshal a bool/int TOML value at all
// (go-toml/v2's custom-unmarshaler hook needs its `unstable` package, not
// worth pinning against for this), so these two fields decode into `any`
// here and get stringified in toOverride below, matching dasel's old
// text-regardless-of-type behavior.
type rawOverride struct {
	Name        string   `toml:"name"`
	Pin         string   `toml:"pin"`
	SkipCheck   any      `toml:"skip_check"`
	MakepkgArgs []string `toml:"makepkg_args"`
	Patches     []string `toml:"patches"`
	MemPerJobMB any      `toml:"mem_per_job_mb"`
	Notes       string   `toml:"notes"`
}

func scalarToString(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64)
	default:
		return fmt.Sprint(x)
	}
}

func (r rawOverride) toOverride() Override {
	return Override{
		Name: r.Name, Pin: r.Pin,
		SkipCheck:   scalarToString(r.SkipCheck),
		MakepkgArgs: r.MakepkgArgs,
		Patches:     r.Patches,
		MemPerJobMB: scalarToString(r.MemPerJobMB),
		Notes:       r.Notes,
	}
}

type overridesFile struct {
	Override []rawOverride `toml:"override"`
}

func archConfPath(root, arch string) string    { return filepath.Join(root, "config/arches", arch+".toml") }
func packagesPath(root, arch string) string    { return filepath.Join(root, "config/packages", arch+".toml") }
func overridesPath(root, arch string) string   { return filepath.Join(root, "config/overrides", arch+".toml") }
func groupPath(root, name string) string       { return filepath.Join(root, "config/groups", name+".toml") }

func loadTOML(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return toml.Unmarshal(b, v)
}

// LoadArch reads config/arches/<arch>.toml. Returns an error if the file is
// missing or malformed — callers should treat that as "arch doesn't exist"
// the same way archExists's os.Stat check does today.
func LoadArch(root, arch string) (Arch, error) {
	var a Arch
	err := loadTOML(archConfPath(root, arch), &a)
	return a, err
}

// ArchStat returns config/arches/<arch>.toml's mtime, for callers that want
// their own external caching keyed by it (main.go's archStaticCache used
// this pattern against dasel's spawn cost; native parsing is cheap enough
// that most callers don't need to bother, but the stat is exposed for parity
// with anything that still wants it).
func ArchStat(root, arch string) (os.FileInfo, error) {
	return os.Stat(archConfPath(root, arch))
}

// ArchNames lists every defined arch (config/arches/*.toml). Sorted by full
// filename (including the .toml extension) before trimming it, not by the
// trimmed name — "essentials-atom.toml" < "essentials.toml" (`-` < `.`) but
// "essentials" < "essentials-atom" (shorter prefix sorts first), so sorting
// after trimming would silently reorder any name that's a prefix of another.
// Matches the original bash/dasel-era Go code's sort.Strings(files) order.
func ArchNames(root string) []string {
	files, _ := filepath.Glob(filepath.Join(root, "config/arches", "*.toml"))
	sort.Strings(files)
	out := make([]string, 0, len(files))
	for _, f := range files {
		out = append(out, trimTOML(f))
	}
	return out
}

// LoadPackages reads config/packages/<arch>.toml's [[package]] entries.
// Returns nil, nil if the file doesn't exist (an arch with no extras).
func LoadPackages(root, arch string) ([]Package, error) {
	var f packagesFile
	err := loadTOML(packagesPath(root, arch), &f)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return f.Package, nil
}

// LoadGroup reads one config/groups/<name>.toml. Returns the zero Group if
// the file doesn't exist (mirrors bin/lib/common.sh's group_members, which
// silently returns nothing for an unknown group rather than erroring).
func LoadGroup(root, name string) (Group, error) {
	var g Group
	err := loadTOML(groupPath(root, name), &g)
	if err != nil && os.IsNotExist(err) {
		return Group{}, nil
	}
	return g, err
}

// GroupNames lists every defined group (config/groups/*.toml). Sorted by full
// filename before trimming — see ArchNames' comment for why that's not the
// same as sorting the trimmed names.
func GroupNames(root string) []string {
	files, _ := filepath.Glob(filepath.Join(root, "config/groups", "*.toml"))
	sort.Strings(files)
	out := make([]string, 0, len(files))
	for _, f := range files {
		out = append(out, trimTOML(f))
	}
	return out
}

// LoadOverrides reads config/overrides/<arch>.toml's [[override]] entries.
// Returns nil, nil if the file doesn't exist (an arch with no overrides).
func LoadOverrides(root, arch string) ([]Override, error) {
	var f overridesFile
	err := loadTOML(overridesPath(root, arch), &f)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	out := make([]Override, len(f.Override))
	for i, r := range f.Override {
		out[i] = r.toOverride()
	}
	return out, nil
}

// OverrideFor returns the override entry named pkg, if any.
func OverrideFor(root, arch, pkg string) (Override, bool) {
	overrides, _ := LoadOverrides(root, arch)
	for _, o := range overrides {
		if o.Name == pkg {
			return o, true
		}
	}
	return Override{}, false
}

// EffectivePackage is one row of EffectivePackages' result.
type EffectivePackage struct {
	Name   string
	Source string // resolved: explicit override, else "local"/"upstream" inferred
	Origin string // comma-joined group name(s), or "individual"
}

// EffectivePackages mirrors bin/lib/common.sh's effective_packages field-for-
// field: the union of arch's enabled groups' members and its per-arch extras
// (config/packages/<arch>.toml), deduped by name, sorted by name to match the
// bash version's trailing `| sort`.
//
//   - source: the explicit per-arch override if set, else "local" when
//     pkgbuilds/<arch>/<name>/PKGBUILD exists, else "upstream".
//   - origin: comma-joined group name(s) the package belongs to, or
//     "individual" if it's only a packages.toml entry with no group
//     membership. A packages.toml entry that merely sets source=aur/local on
//     an existing group member does NOT relabel it "individual" — origin is
//     only ever set to "individual" when no group origin exists yet, mirroring
//     effective_packages' explicit comment on this exact point.
func EffectivePackages(root, arch string) ([]EffectivePackage, error) {
	a, err := LoadArch(root, arch)
	if err != nil {
		return nil, err
	}

	origin := map[string]string{}
	for _, g := range a.Groups {
		grp, err := LoadGroup(root, g)
		if err != nil {
			return nil, err
		}
		for _, p := range grp.Packages {
			if origin[p] == "" {
				origin[p] = g
			} else {
				origin[p] += "," + g
			}
		}
	}

	src := map[string]string{}
	pkgs, err := LoadPackages(root, arch)
	if err != nil {
		return nil, err
	}
	for _, p := range pkgs {
		if p.Name == "" {
			continue
		}
		src[p.Name] = p.Source
		if origin[p.Name] == "" {
			origin[p.Name] = "individual"
		}
	}

	out := make([]EffectivePackage, 0, len(origin))
	for name, o := range origin {
		effSrc := src[name]
		if effSrc == "" {
			if _, err := os.Stat(filepath.Join(root, "pkgbuilds", arch, name, "PKGBUILD")); err == nil {
				effSrc = "local"
			} else {
				effSrc = "upstream"
			}
		}
		out = append(out, EffectivePackage{Name: name, Source: effSrc, Origin: o})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func trimTOML(path string) string {
	base := filepath.Base(path)
	return base[:len(base)-len(filepath.Ext(base))]
}
