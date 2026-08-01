#!/bin/bash
# Renders the app icon and packs it into Resources/Vitals.icns.
#
# Run from the repository root. The .icns is committed, so this only needs
# re-running when the artwork changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
swift "$ROOT/scripts/make-icon.swift" "$WORK/icon-1024.png"

ICONSET="$WORK/Vitals.iconset"
mkdir -p "$ICONSET"

# The ten entries iconutil requires. A missing size is a silent failure:
# Finder falls back to a blurry upscale rather than reporting anything.
sips -z 16 16      "$WORK/icon-1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32      "$WORK/icon-1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32      "$WORK/icon-1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64      "$WORK/icon-1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128    "$WORK/icon-1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256    "$WORK/icon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256    "$WORK/icon-1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512    "$WORK/icon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512    "$WORK/icon-1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$WORK/icon-1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil --convert icns "$ICONSET" --output "$OUT/Vitals.icns"
echo "wrote $OUT/Vitals.icns"
