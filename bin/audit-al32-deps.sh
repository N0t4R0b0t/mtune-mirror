#!/usr/bin/env bash
# bin/audit-al32-deps.sh [arch] [repo,repo,...]
#
# Read-only dependency-drift auditor for archlinux32's OWN repo (not this
# project's packages). For every package in the given repos, checks whether
# every declared depends/makedepends/checkdepends spec is actually satisfiable
# by something currently published in those same repos, and reports the ones
# that aren't.
#
# Why this exists: three separate times this session we hit a build that
# failed deep inside prepare()/the final link step -- never a clean
# dependency error -- because archlinux32 bumped one package's sibling
# dependency without rebuilding the package itself to match (qt6-base still
# wanting an old icu75 shim; librsvg still wanting libxml2-legacy; netsurf's
# whole sibling-library family out of sync in both directions). That's a
# systemic pattern in archlinux32's package graph, not three unrelated bugs --
# this finds more of them proactively instead of discovering them one build
# at a time. See docs/archlinux32-upstream-reports.md for the write-ups this
# feeds into.
#
# `pacman -T`/--deptest is NOT used here even though it sounds like the right
# tool: it checks specs against the LOCAL (installed) package database, not a
# sync repo's available packages. Making that work would mean actually
# installing every package in the repo into a scratch root -- thousands of
# real downloads, not just the small .db metadata tarballs this script
# actually needs. Instead this parses the repo databases directly (same
# `bsdtar -xOf <db> --include='*/desc'` extraction installer/bootstrap-
# chroot.sh already uses for the keyring lookup) and reimplements just the
# "is this spec satisfied by anything published" check, using pacman's own
# `vercmp` for version comparison so Arch's epoch/pkgrel/alpha-suffix
# ordering rules don't need reimplementing.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

arch="${1:-i686}"
repos="${2:-core,extra}"
mirror_base="https://mirror.archlinux32.org/$arch"

for bin in bsdtar vercmp curl awk; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin required"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

descs="$tmp/all.desc"
IFS=',' read -ra repo_list <<< "$repos"
desc_files=()
for repo in "${repo_list[@]}"; do
  log "fetching $mirror_base/$repo/$repo.db"
  curl -fsSL "$mirror_base/$repo/$repo.db" -o "$tmp/$repo.db" \
    || die "fetch $repo.db failed (bad repo name, or mirror unreachable?)"
  # Each repo extracts to its OWN file (never appended into with bsdtar
  # itself) -- bsdtar -xO writing into an O_APPEND fd that already has a lot
  # of data in it (i.e. a second/third repo's extraction piling onto the
  # first's output via `>>`) hits a real bug: some entry mid-archive trips a
  # "Seek error: Unknown error -1" and aborts, non-deterministically,
  # whichever entry happens to land at the point libarchive tries to seek an
  # O_APPEND fd (writes on O_APPEND always go to EOF regardless of the seek,
  # which libarchive doesn't expect). `cat`-ing plain, independently-written
  # files together afterward has none of that problem.
  bsdtar -xOf "$tmp/$repo.db" --include='*/desc' > "$tmp/$repo.desc"
  desc_files+=("$tmp/$repo.desc")
done
cat "${desc_files[@]}" > "$descs"

# --- Phase A: parse every package's desc block into two flat TSVs ----------
# providers.tsv: provname<TAB>version   (version empty = unversioned Provides)
# specs.tsv:     pkgname<TAB>specstring (one row per depends/makedepends/
#                                        checkdepends entry; optdepends is
#                                        deliberately skipped -- those are
#                                        non-blocking by design and would
#                                        mostly just add noise here)
#
# Every field in a desc block appears in a fixed order (NAME, ..., VERSION,
# ..., PROVIDES, DEPENDS, ...), so "the most recently seen NAME/VERSION" is
# always the current package's -- one pass, tracking name/ver as we go, is
# enough for all three fields.
providers_tsv="$tmp/providers.tsv"
specs_tsv="$tmp/specs.tsv"
awk '
  /^%NAME%$/     { getline; name = $0; next }
  /^%VERSION%$/  { getline; ver = $0; print name "\t" ver >> providers_out; next }
  /^%PROVIDES%$/ {
    while ((getline line) > 0 && line != "") {
      if (index(line, "=") > 0) {
        pname = substr(line, 1, index(line, "=") - 1)
        pver  = substr(line, index(line, "=") + 1)
      } else { pname = line; pver = "" }
      print pname "\t" pver >> providers_out
    }
    next
  }
  /^%(DEPENDS|MAKEDEPENDS|CHECKDEPENDS)%$/ {
    while ((getline line) > 0 && line != "") print name "\t" line >> specs_out
    next
  }
' providers_out="$providers_tsv" specs_out="$specs_tsv" "$descs"

pkg_count="$(cut -f1 "$providers_tsv" | sort -u | wc -l)"
spec_count="$(wc -l < "$specs_tsv")"
log "parsed $pkg_count packages, $spec_count depends/makedepends/checkdepends entries across: $repos"

# --- Phase B: build an in-memory provider index, check every spec ----------
declare -A providers   # name -> space-separated list of versions ("" = unversioned entry present)
while IFS=$'\t' read -r pname pver; do
  [ -n "$pname" ] || continue
  providers["$pname"]="${providers[$pname]:-} $pver"
done < "$providers_tsv"

# parse_spec <spec> -> sets SPEC_NAME/SPEC_OP/SPEC_VER (SPEC_OP empty = bare)
parse_spec() {
  local spec="$1"
  if [[ "$spec" =~ ^([^\<\>=]+)(\>=|\<=|\>|\<|=)(.*)$ ]]; then
    SPEC_NAME="${BASH_REMATCH[1]}"
    SPEC_OP="${BASH_REMATCH[2]}"
    SPEC_VER="${BASH_REMATCH[3]}"
  else
    SPEC_NAME="$spec"; SPEC_OP=""; SPEC_VER=""
  fi
}

# vercmp_ok <have> <op> <want> -> success if <have> <op> <want> holds
vercmp_ok() {
  local have="$1" op="$2" want="$3" cmp
  cmp="$(vercmp "$have" "$want")"
  case "$op" in
    '>=') [ "$cmp" -ge 0 ] ;;
    '<=') [ "$cmp" -le 0 ] ;;
    '>')  [ "$cmp" -gt 0 ] ;;
    '<')  [ "$cmp" -lt 0 ] ;;
    '=')  [ "$cmp" -eq 0 ] ;;
    *) return 1 ;;
  esac
}

report="$tmp/report.txt"
: > "$report"
while IFS=$'\t' read -r pkgname spec; do
  [ -n "$spec" ] || continue
  parse_spec "$spec"
  cands="${providers[$SPEC_NAME]:-}"
  if [ -z "$cands" ]; then
    printf '%s\tMISSING\t%s\n' "$pkgname" "$spec" >> "$report"
    continue
  fi
  if [ -z "$SPEC_OP" ]; then
    continue  # bare name/soname dep -- any provider at all satisfies it
  fi
  satisfied=0
  for v in $cands; do
    [ -n "$v" ] || continue
    if vercmp_ok "$v" "$SPEC_OP" "$SPEC_VER"; then satisfied=1; break; fi
  done
  if [ "$satisfied" -eq 0 ]; then
    printf '%s\tVERSION\t%s\n' "$pkgname" "$spec" >> "$report"
  fi
done < "$specs_tsv"

unmet="$(wc -l < "$report")"
if [ "$unmet" -eq 0 ]; then
  log "no drift found across $pkg_count packages / $spec_count dependency specs ($arch: $repos)"
  exit 0
fi

log "$unmet unsatisfied dependency spec(s) found across $arch: $repos"
printf '\n%-30s %-9s %s\n' "PACKAGE" "REASON" "UNSATISFIED SPEC"
printf '%-30s %-9s %s\n' "-------" "------" "-----------------"
sort "$report" | while IFS=$'\t' read -r pkgname reason spec; do
  printf '%-30s %-9s %s\n' "$pkgname" "$reason" "$spec"
done
