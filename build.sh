#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-release}"
mkdir -p "$root/dist"
if [ "$mode" = "release" ]; then
  swiftc -O -framework AppKit -framework SwiftUI "$root/main.swift" -o "$root/dist/opencode-toast"
elif [ "$mode" = "debug" ]; then
  swiftc -framework AppKit -framework SwiftUI "$root/main.swift" -o "$root/dist/opencode-toast"
else
  printf 'usage: %s [debug|release]\n' "$0" >&2
  exit 1
fi