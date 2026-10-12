#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fetches the libretro FCEUmm core (GPL-2.0) at a pinned commit into
# third_party/fceumm, which git ignores: TinyNES does not carry its source.
# Anything built from it, such as the nes_bench program, is GPL-2.0 too and
# stays in build/.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
url=https://github.com/libretro/libretro-fceumm.git
commit=ac0d00a7fc01166f84c7bac01d1084ebfd2b865e
dir="${FCEUMM_DIR:-$root/third_party/fceumm}"

if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
fi
if [[ "$(git -C "$dir" rev-parse -q --verify HEAD || true)" != "$commit" ]]; then
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --detach "$commit"
fi
[[ "$(git -C "$dir" rev-parse HEAD)" == "$commit" ]] || {
    echo "fceumm: HEAD is not $commit" >&2; exit 1; }
[[ -z "$(git -C "$dir" status --porcelain)" ]] || {
    echo "fceumm: $dir has local changes" >&2; exit 1; }
echo "fceumm $commit in $dir"
