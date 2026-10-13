#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fetches Daniel Hepper's font8x8 (public domain) at a pinned commit into
# third_party/font8x8, which git ignores, and writes its basic Latin glyphs
# as fpga/ae350_soc/desk_font.hex, the desk layer's font, with
# tools/gen_desk_font.py. The result is committed, so a build does not need
# this; run it to check or regenerate the file.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
url=https://github.com/dhepper/font8x8.git
commit=8e279d2d864e79128e96188a6b9526cfa3fbfef9
dir="${FONT8X8_DIR:-$root/third_party/font8x8}"

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
    echo "font8x8: HEAD is not $commit" >&2; exit 1; }
[[ -z "$(git -C "$dir" status --porcelain)" ]] || {
    echo "font8x8: $dir has local changes" >&2; exit 1; }
python3 -I "$root/tools/gen_desk_font.py" "$dir/font8x8_basic.h" \
    -o "$root/fpga/ae350_soc/desk_font.hex"
echo "font8x8 $commit in $dir"
