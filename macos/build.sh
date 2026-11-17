#!/bin/sh
set -eu
src="$(cd "$(dirname "$0")/.." && pwd)"
dst="${1:-$src/build-mac}"
app="$dst/Bonfire.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$src/macos/Info.plist" "$app/Contents/Info.plist"
cp "$src/vendor/NOTICES.txt" "$app/Contents/Resources/"
python3 "$src/tools/resources.py" macos "$app/Contents/Resources"
set -- "$src/core/"*.cpp "$src/adapters/catalog.cpp"
for id in $(sed -n 's/^BONFIRE_GAME(\([a-z0-9_]*\)).*/\1/p' "$src/adapters/catalog.def"); do
  set -- "$@" "$src/adapters/$id/$id.cpp"
done
xcrun clang -arch arm64 -mmacosx-version-min=13.0 -O2 -c "$src/vendor/puff.c" -o "$dst/puff.o"
xcrun clang++ -std=c++17 -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc -fblocks -O2 \
  "$@" "$src/app/runtime.cpp" "$src/macos/platform.mm" "$src/macos/Presentation.mm" "$src/macos/App.mm" "$dst/puff.o" \
  -framework AppKit -framework CoreServices -framework CoreFoundation -framework UniformTypeIdentifiers -framework Foundation \
  -o "$app/Contents/MacOS/Bonfire"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
