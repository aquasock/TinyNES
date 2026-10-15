#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fetches 100th Coin's AccuracyCoin (MIT), an NES accuracy test cartridge
# and its assembly source, at a pinned commit into third_party/accuracycoin,
# which git ignores. tools/accuracycoin.py runs the cartridge on the PC build
# of nes_bench and reads its results using the source's own test tables.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
url=https://github.com/100thCoin/AccuracyCoin.git
commit=6bee919529289c555803b612b8c9e4f7eaaeeabb
dir="${ACCURACYCOIN_DIR:-$root/third_party/accuracycoin}"

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
    echo "accuracycoin: HEAD is not $commit" >&2; exit 1; }
[[ -z "$(git -C "$dir" status --porcelain)" ]] || {
    echo "accuracycoin: $dir has local changes" >&2; exit 1; }
echo "accuracycoin $commit in $dir"
