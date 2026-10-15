#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# The player's zip reader on the PC (tests/cart_zip_host.c), over the .zip
# files given or, with a folder, every .zip in it.
#   tests/test_cart_zip.sh <folder | file.zip...>
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
common="$root/third_party/fceumm/src/drivers/libretro/libretro-common"
[[ -d "$common" ]] || { echo "run tools/fetch_fceumm.sh first" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cc -std=c11 -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
   -I "$root/firmware/apps/nes_bench" -I "$common/include" \
   "$root/tests/cart_zip_host.c" "$root/firmware/apps/nes_bench/cart_zip.c" \
   -x c -w "$common/encodings/encoding_deflate.c" -o "$work/tb"
if [[ $# -eq 1 && -d "$1" ]]; then
    shopt -s nullglob
    files=("$1"/*.zip)
else
    files=("$@")
fi
"$work/tb" "${files[@]}"
