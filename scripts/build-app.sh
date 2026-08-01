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

# shellcheck source=lib-version.sh
source "$ROOT/scripts/lib-version.sh"

# A git-less export would otherwise die mid-way through with a raw
# "fatal: not a git repository" from whichever of describe/rev-list happens
# to run first. Fail up front with a message that says why.
vitals_require_git "$ROOT" || exit 1

# Version derived, never declared. An untagged working build says so instead of
# claiming a release number nobody minted.
VERSION="$(vitals_version "$ROOT")"
BUILD_NUMBER="$(vitals_build_number "$ROOT")"

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

ZIP="$OUT/Vitals-$VERSION.zip"
# Remove every old zip, not just the one whose name matches this version —
# otherwise stale zips from earlier builds/versions just accumulate in build/.
rm -f "$OUT"/Vitals-*.zip
# ditto, not zip: a plain zip mangles a bundle's symlinks and resource forks.
# No --sequesterRsrc: the bundle has no resource forks or symlinks for it to
# protect, and it only adds a __MACOSX/ sibling that looks like a stray folder
# to anyone extracting with plain `unzip` instead of Archive Utility.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Packaged $ZIP"

# The zip is what a downloader actually receives, and ditto/zip round-tripping
# is exactly the kind of thing that can silently mangle a bundle (permissions,
# the code signature's extended attributes, etc.) even when the pre-zip copy
# verified cleanly. Extract it and run the full verifier again rather than
# trusting the round-trip because it was checked by hand once.
echo
echo "==> Verifying the zip round-trips"
ZIP_CHECK="$(mktemp -d)"
trap 'rm -rf "$ZIP_CHECK"' EXIT
ditto -x -k "$ZIP" "$ZIP_CHECK"
"$ROOT/scripts/verify-app.sh" "$ZIP_CHECK/Vitals.app"
