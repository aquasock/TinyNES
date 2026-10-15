#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Saves the changes made in third_party/fceumm, beyond the patches already in
# patches/fceumm/, as the next patch of the series:
#
#   tools/fceumm_patch.sh <short-name> "<one-line subject>"
#
# writes patches/fceumm/NNNN-<short-name>.patch with the subject and a licence
# line ahead of the diff; edit its header to say what the change fixes and
# what it was checked against. tools/fetch_fceumm.sh then accepts the checkout
# as the pinned commit plus the series.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir="${FCEUMM_DIR:-$root/third_party/fceumm}"
[[ $# -eq 2 ]] || { echo "usage: $0 <short-name> \"<subject>\"" >&2; exit 2; }
name=$1 subject=$2
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "name: lower case, digits and dashes" >&2; exit 2; }
commit=$(sed -n 's/^commit=//p' "$root/tools/fetch_fceumm.sh")

shopt -s nullglob
patches=("$root"/patches/fceumm/*.patch)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The tree the series gives, and the tree the checkout has, new files
# included, each built in an index of its own.
export GIT_INDEX_FILE="$tmp/series"
git -C "$dir" read-tree "$commit"
for patch in "${patches[@]}"; do
    git -C "$dir" apply --cached "$patch"
done
series=$(git -C "$dir" write-tree)
export GIT_INDEX_FILE="$tmp/checkout"
git -C "$dir" read-tree HEAD
git -C "$dir" add -A
checkout=$(git -C "$dir" write-tree)
unset GIT_INDEX_FILE
git -C "$dir" diff-tree -p --no-color "$series" "$checkout" > "$tmp/diff"
[[ -s "$tmp/diff" ]] || { echo "no changes beyond the series" >&2; exit 1; }

number=$(printf '%04d' $(( ${#patches[@]} + 1 )))
out="$root/patches/fceumm/$number-$name.patch"
{
    echo "Subject: $subject"
    echo
    echo "License: GPL-2.0-or-later, as the FCEUmm code it changes (patches/fceumm/README.md)."
    echo
    echo "---"
    cat "$tmp/diff"
} > "$out"
echo "wrote $out"
