#!/usr/bin/env bash
# sunshine's PKGBUILD "auto-detects" CUDA/NVENC via `pacman -Qi cuda &>
# /dev/null`, but that check runs at the TOP of the PKGBUILD -- when makepkg
# first sources it to read pkgname/pkgver, before makepkg's own dependency
# installer has run. cuda is never installed yet at that point even once
# it's in makedepends, so `_use_cuda` never flips from "detect" to "true",
# and build()'s `[[ "${_use_cuda::1}" != "t" ]]` check (which gates BOTH the
# -DSUNSHINE_ENABLE_CUDA=OFF cmake flag and the CUDA_PATH/NVCC_CCBIN exports)
# takes the false branch every time -- confirmed 2026-10-20: a build with
# cuda forced into makedepends alone "succeeded" but logged zero CUDA output
# at all (no "-- CUDA Architectures", no "-- CUDA not found" fatal, nothing),
# meaning SUNSHINE_ENABLE_CUDA=OFF was passed silently and it took the exact
# same non-NVENC fallback path as before the makedepends change.
#
# Two separate fixes, both needed:
#  1. force cuda into makedepends, so it's actually *present* at build() time
#     for nvcc/headers (makepkg's own detection timing bug doesn't change
#     that cuda still has to be installed for the compile to work at all).
#  2. force the _use_cuda default straight to "true", bypassing the
#     too-early detection entirely, so build()'s check takes the true branch
#     regardless of what pacman saw at source-time.
#
# A sed hook (not an override patch) for both, because this PKGBUILD is
# regenerated upstream on every release (pkgver is a build-timestamp,
# _commit bumps every time) -- a positional diff against it would go stale
# fast; this only needs the makedepends=( and _use_cuda:=detect lines, both
# far more stable than the surrounding boilerplate, to still be there.
#
# cuda itself is a big (~2.4GB) download/~5GB installed Manjaro extra-repo
# package (deps: cccl, opencl-nvidia, python, gcc15, all plain userspace --
# opencl-nvidia needs no GPU/kernel module present to install), fine for this
# CT's build-only chroot which never touches real hardware either way; actual
# NVENC use is an orthogonal matter of the box sunshine runs on.
set -euo pipefail
grep -q "^makedepends=(" PKGBUILD || { echo "post_fetch: no makedepends=( line found in PKGBUILD" >&2; exit 1; }
grep -q '_use_cuda:=detect' PKGBUILD || { echo "post_fetch: no _use_cuda:=detect default found in PKGBUILD" >&2; exit 1; }
sed -i "/^makedepends=(/a\\  'cuda'" PKGBUILD
sed -i 's/_use_cuda:=detect/_use_cuda:=true/' PKGBUILD
