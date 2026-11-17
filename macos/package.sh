#!/bin/sh
set -eu
src="$(cd "$(dirname "$0")/.." && pwd)"
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
dst="$2"
mkdir -p "$dst"
dst="$(cd "$dst" && pwd)"
version="$(cat "$src/VERSION")"
name="Bonfire-$version-macOS-arm64"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dst/$name-Portable.zip"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/root"
ditto "$app" "$stage/root/Bonfire.app"
python3 - "$stage/components.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as stream:
    plistlib.dump([dict(RootRelativeBundlePath="Bonfire.app", BundleIsRelocatable=False,
                        BundleIsVersionChecked=True, BundleHasStrictIdentifier=True,
                        BundleOverwriteAction="upgrade")], stream)
PY
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" \
    --install-location /Applications --identifier app.bonfire.savetransfer.installer \
    --version "$(printf '%s' "$version" | sed 's/-beta\././')" "$dst/$name-Installer.pkg"
