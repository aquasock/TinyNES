#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fetches the libretro FCEUmm core (GPL-2.0) at a pinned commit into
# third_party/fceumm, which git ignores, and applies TinyNES's patches to it,
# patches/fceumm/*.patch in name order: TinyNES carries those patches, which
# are GPL-2.0 like the code they change (patches/fceumm/README.md), and not
# the core's source. Anything built from it, such as the nes_bench program, is
# GPL-2.0 too and stays in build/.
#
# The checkout is accepted only as the pinned commit, or that commit with
# exactly the patch series applied; anything else is refused rather than
# overwritten, because it is work not yet saved as a patch, which
# tools/fceumm_patch.sh does.
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

shopt -s nullglob
patches=("$root"/patches/fceumm/*.patch)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The tree the series should give, built in an index of its own.
export GIT_INDEX_FILE="$tmp/expected"
git -C "$dir" read-tree "$commit"
for patch in "${patches[@]}"; do
    git -C "$dir" apply --cached "$patch" ||
        { echo "fceumm: $(basename "$patch") does not apply" >&2; exit 1; }
done
expected=$(git -C "$dir" write-tree)
# The tree the checkout has now, untracked files included.
export GIT_INDEX_FILE="$tmp/actual"
git -C "$dir" read-tree HEAD
git -C "$dir" add -A
actual=$(git -C "$dir" write-tree)
unset GIT_INDEX_FILE
git -C "$dir" update-index -q --refresh >/dev/null || true

if [[ "$actual" == "$expected" ]]; then
    :
elif [[ "$actual" == "$(git -C "$dir" rev-parse "$commit^{tree}")" ]]; then
    for patch in "${patches[@]}"; do
        git -C "$dir" apply "$patch"
    done
else
    echo "fceumm: $dir has changes that are not the patch series;" \
         "save them with tools/fceumm_patch.sh or discard them" >&2
    exit 1
fi
echo "fceumm $commit + ${#patches[@]} patch(es) in $dir"
