#!/bin/sh
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc "$root/tests/mac_update_service.mm" "$root/macos/BundleUpdate.mm" \
  "$root/macos/Presentation.mm" "$root/app/updates.cpp" -framework AppKit -framework Foundation -o "$work/check"
"$work/check" "$work"
