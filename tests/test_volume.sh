#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# The master volume's gain on the PC (tests/volume_host.c).
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cc -std=c11 -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
   -I "$root/firmware/include" "$root/tests/volume_host.c" -o "$work/tb"
"$work/tb"
