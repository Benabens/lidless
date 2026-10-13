#!/bin/bash
# Builds dist/Lidless.app from the Swift package.
#
#   scripts/bundle.sh            universal release build (Apple Silicon + Intel)
#   scripts/bundle.sh --native   this Mac's architecture only (faster)
#
# The bundle is signed ad hoc: enough to run on the Mac that built it. Nothing is installed.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

native_only=""
for argument in "$@"; do
    case "$argument" in
        --native) native_only=1 ;;
        *) echo "usage: scripts/bundle.sh [--native]" >&2; exit 64 ;;
    esac
done

swift="$root/scripts/swiftw"
products=(Lidless lidless-hook)
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/LidlessCore/Version.swift)"
[ -n "$version" ] || { echo "bundle.sh: could not read the version" >&2; exit 1; }

app="$root/dist/Lidless.app"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# SwiftPM can only produce a universal binary in one go with Xcode installed, so each
# architecture is built on its own and the slices are merged with lipo.
if [ -n "$native_only" ]; then
    architectures=("$(uname -m)")
else
    architectures=(arm64 x86_64)
fi

for architecture in "${architectures[@]}"; do
    echo "==> Building for $architecture"
    "$swift" build -c release --arch "$architecture"
done

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for product in "${products[@]}"; do
    slices=()
    for architecture in "${architectures[@]}"; do
        slices+=("$root/.build/$architecture-apple-macosx/release/$product")
    done
    lipo -create "${slices[@]}" -output "$app/Contents/MacOS/$product"
done
sed "s/__VERSION__/$version/g" Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"

# The icon is drawn by the app itself, so the repository holds no binary artwork.
"$app/Contents/MacOS/Lidless" --export-icons "$staging"
iconutil --convert icns "$staging/AppIcon.iconset" --output "$app/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad hoc)"
codesign --force --sign - "$app/Contents/MacOS/lidless-hook"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

echo "==> Done: $app ($version, $(lipo -archs "$app/Contents/MacOS/Lidless"))"
