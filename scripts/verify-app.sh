#!/bin/bash
# Checks a built Vitals.app. Verifies the artifact, not the script that made it.
#
# Run: ./scripts/verify-app.sh [path/to/Vitals.app]
set -uo pipefail   # NOT -e: every check must run so all failures are reported

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Vitals.app}"
PLIST="$APP/Contents/Info.plist"
FAILED=0

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

echo "==> Verifying $APP"

# --- Executable -----------------------------------------------------------
if [ -x "$APP/Contents/MacOS/Vitals" ]; then
    pass "executable present"
else
    fail "Contents/MacOS/Vitals missing or not executable"
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Vitals" 2>/dev/null || echo "")"
if [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]; then
    pass "universal binary ($ARCHS)"
else
    fail "expected arm64 and x86_64, got: ${ARCHS:-none}"
fi

# --- Info.plist -----------------------------------------------------------
if plutil -lint "$PLIST" >/dev/null 2>&1; then
    pass "Info.plist parses"
else
    fail "Info.plist is malformed"
fi

check_key() {
    local key="$1" expected="$2"
    local actual
    actual="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null || echo "")"
    if [ "$actual" = "$expected" ]; then
        pass "$key = $expected"
    else
        fail "$key: expected '$expected', got '${actual:-missing}'"
    fi
}

check_key CFBundleIdentifier    com.drket.Vitals
check_key CFBundleExecutable    Vitals
check_key LSMinimumSystemVersion 26.0
check_key CFBundleIconFile      Vitals

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null || echo "")"
if [ -n "$VERSION" ]; then
    pass "CFBundleShortVersionString = $VERSION"
else
    fail "CFBundleShortVersionString is empty"
fi

# --- Icon -----------------------------------------------------------------
# A truncated iconset is a classic silent failure: Finder shows a blurry
# upscale rather than reporting anything wrong.
ICONSET_CHECK="$(mktemp -d)"
if iconutil --convert iconset "$APP/Contents/Resources/Vitals.icns" \
        --output "$ICONSET_CHECK/out.iconset" >/dev/null 2>&1; then
    COUNT="$(ls "$ICONSET_CHECK/out.iconset" | wc -l | tr -d ' ')"
    if [ "$COUNT" -eq 10 ]; then
        pass "icns contains all 10 sizes"
    else
        fail "icns contains $COUNT sizes, expected 10"
    fi
else
    fail "icns missing or unreadable"
fi
rm -rf "$ICONSET_CHECK"

# --- Signature ------------------------------------------------------------
if codesign --verify --strict "$APP" >/dev/null 2>&1; then
    pass "code signature verifies"
else
    fail "codesign --verify --strict failed"
fi

# --- Launch ---------------------------------------------------------------
# The check that matters most. This project shipped an app that ran perfectly
# and invisibly for three milestones because nothing confirmed a window existed.
echo "  ...    launching (up to 30s)"
open -a "$APP" 2>/dev/null
WINDOWS=0
for _ in $(seq 1 30); do
    sleep 1
    WINDOWS="$(osascript -e 'tell application "System Events" to tell process "Vitals" to count windows' 2>/dev/null || echo 0)"
    [ "${WINDOWS:-0}" -ge 1 ] && break
done
if [ "${WINDOWS:-0}" -ge 1 ]; then
    pass "launched and showed $WINDOWS window(s)"
else
    fail "launched but never showed a window"
fi
osascript -e 'tell application "Vitals" to quit' >/dev/null 2>&1 || pkill -x Vitals || true

echo
if [ "$FAILED" -eq 0 ]; then
    echo "==> All checks passed"
else
    echo "==> VERIFICATION FAILED"
fi
exit "$FAILED"
