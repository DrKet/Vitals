#!/bin/bash
# Builds Vitals.app from the SwiftPM package.
#
# Package.swift stays the single source of truth; this only assembles what
# `swift build` produced into the bundle layout macOS expects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/VitalsCore"
OUT="$ROOT/build"
APP="$OUT/Vitals.app"

# Version derived, never declared. An untagged working build says so instead of
# claiming a release number nobody minted.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    VERSION="0.0.0-dev+$(git -C "$ROOT" rev-parse --short HEAD)"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"

echo "==> Building universal release binary (this takes a few minutes)"
cd "$PKG"
swift build -c release --arch arm64 --arch x86_64 --product VitalsApp

# A universal build lands in .build/apple/Products/Release, NOT .build/release.
# Hardcoding the latter silently picks up a stale single-arch binary.
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --product VitalsApp --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/VitalsApp" "$APP/Contents/MacOS/Vitals"
cp "$ROOT/Resources/Vitals.icns" "$APP/Contents/Resources/Vitals.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vitals</string>
    <key>CFBundleDisplayName</key><string>Vitals</string>
    <key>CFBundleIdentifier</key><string>com.drket.Vitals</string>
    <key>CFBundleExecutable</key><string>Vitals</string>
    <key>CFBundleIconFile</key><string>Vitals</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc — see README on Gatekeeper)"
codesign --force --sign - --timestamp=none "$APP"

echo "==> Built $APP  version $VERSION  build $BUILD_NUMBER"

echo
"$ROOT/scripts/verify-app.sh" "$APP"
