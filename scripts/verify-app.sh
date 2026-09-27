#!/bin/bash
# Checks a built Vitals.app. Verifies the artifact, not the script that made it.
#
# Run: ./scripts/verify-app.sh [path/to/Vitals.app]
set -uo pipefail   # NOT -e: every check must run so all failures are reported

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Vitals.app}"
# Canonicalize: /var (and a temp dir under it, e.g. from mktemp -d) is a
# symlink to /private/var on macOS, and `ps -o comm=` reports a launched
# process's RESOLVED path. Comparing an un-resolved $APP against that later
# would never match and the launch check would false-FAIL on any bundle
# reached through a symlinked path — exactly what verifying an extracted zip
# under mktemp -d does.
if [ -d "$APP" ]; then
    APP="$(cd "$APP" && pwd -P)"
fi
PLIST="$APP/Contents/Info.plist"
FAILED=0

# shellcheck source=lib-version.sh
source "$ROOT/scripts/lib-version.sh"

# One temp dir for the whole run, cleaned on any exit — including Ctrl-C
# during the 30-second launch poll, which previously leaked a directory.
VERIFY_TMP="$(mktemp -d)"
trap 'rm -rf "$VERIFY_TMP"' EXIT

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

# Decision 5 is the marquee decision on how this number is derived, and it's
# exactly what --abbrev=0 silently violated (Critical 2): the version has to
# match what THIS repo currently reports, not merely be present.
EXPECTED_VERSION="$(vitals_version "$ROOT")"
if [ "$VERSION" = "$EXPECTED_VERSION" ]; then
    pass "CFBundleShortVersionString matches the repo ($EXPECTED_VERSION)"
else
    fail "CFBundleShortVersionString '$VERSION' does not match the repo's '$EXPECTED_VERSION'"
fi

BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$PLIST" 2>/dev/null || echo "")"
if [[ -n "$BUILD_NUMBER" && "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    pass "CFBundleVersion = $BUILD_NUMBER"
else
    fail "CFBundleVersion: expected a non-empty number, got '${BUILD_NUMBER:-missing}'"
fi

# --- Icon -----------------------------------------------------------------
# A truncated iconset is a classic silent failure: Finder shows a blurry
# upscale rather than reporting anything wrong. Checking the count alone is
# not enough either — ten wrong-sized entries, or a different app's .icns
# that happens to also have ten sizes, would pass a count-only check. Assert
# the exact filenames make-icon.sh is supposed to have produced.
ICONSET_CHECK="$VERIFY_TMP/out.iconset"
EXPECTED_ICON_NAMES=(
    icon_16x16.png icon_16x16@2x.png
    icon_32x32.png icon_32x32@2x.png
    icon_128x128.png icon_128x128@2x.png
    icon_256x256.png icon_256x256@2x.png
    icon_512x512.png icon_512x512@2x.png
)
if iconutil --convert iconset "$APP/Contents/Resources/Vitals.icns" \
        --output "$ICONSET_CHECK" >/dev/null 2>&1; then
    MISSING=()
    for name in "${EXPECTED_ICON_NAMES[@]}"; do
        [ -f "$ICONSET_CHECK/$name" ] || MISSING+=("$name")
    done
    EXTRA_COUNT="$(ls "$ICONSET_CHECK" | wc -l | tr -d ' ')"
    if [ "${#MISSING[@]}" -eq 0 ] && [ "$EXTRA_COUNT" -eq "${#EXPECTED_ICON_NAMES[@]}" ]; then
        pass "icns contains all 10 expected sizes"
    elif [ "${#MISSING[@]}" -eq 0 ]; then
        fail "icns contains $EXTRA_COUNT entries, expected exactly the 10 named sizes"
    else
        fail "icns is missing: ${MISSING[*]}"
    fi
else
    fail "icns missing or unreadable"
fi

# --- Signature ------------------------------------------------------------
if codesign --verify --strict "$APP" >/dev/null 2>&1; then
    pass "code signature verifies"
else
    fail "codesign --verify --strict failed"
fi

# --- Launch ---------------------------------------------------------------
# The check that matters most. This project shipped an app that ran perfectly
# and invisibly for three milestones because nothing confirmed a window existed.
#
# Identifying "the app" by process NAME is not enough: `tell process "Vitals"`
# matches any process named Vitals, including a real, already-running Vitals
# while we're verifying an unrelated, broken copy — proven by launching a
# stub bundle (an executable that exits immediately) alongside a real running
# Vitals and watching this check pass against the stub. So:
#   1. refuse to run at all if a Vitals process is already alive — there is no
#      way to tell its window from the one under test;
#   2. launch a brand-new instance (`open -n`), capturing its exit status
#      instead of discarding it;
#   3. resolve the PID whose executable is exactly this bundle's binary
#      (`ps -o comm=` reports the full path for a LaunchServices-started
#      process, so this can't be fooled by a same-named process elsewhere);
#   4. query and quit *that* PID specifically, and wait for it to actually
#      exit before returning.
echo "  ...    launching (up to 30s)"

VITALS_BIN="$APP/Contents/MacOS/Vitals"

pid_at_path() {
    # Full comm strings can contain spaces; `read` puts everything after the
    # first field into the last variable, spaces and all, so this compares
    # correctly.
    ps -axo pid=,comm= | while read -r p c; do
        if [ "$c" = "$VITALS_BIN" ]; then
            echo "$p"
            return
        fi
    done
}

if pgrep -x Vitals >/dev/null 2>&1; then
    fail "a process named Vitals is already running — quit it first; this check can't tell its window from the bundle under test"
else
    LAUNCH_LOG="$VERIFY_TMP/open.log"
    if ! open -n "$APP" >"$LAUNCH_LOG" 2>&1; then
        fail "open -n failed to launch the bundle: $(tr '\n' ' ' < "$LAUNCH_LOG")"
    else
        PID=""
        for _ in $(seq 1 30); do
            PID="$(pid_at_path)"
            [ -n "$PID" ] && break
            sleep 1
        done

        if [ -z "$PID" ]; then
            fail "launched but no process at $VITALS_BIN ever appeared"
        else
            # Named, not just counted: with a MenuBarExtra in the process too,
            # a bare window count could be satisfied by its status-item panel
            # rather than the main window this check exists to prove. "Vitals"
            # is the `Window` scene's own title (`VitalsApp.swift`), so this
            # counts only that one.
            WINDOWS=0
            for _ in $(seq 1 30); do
                WINDOWS="$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to count (windows whose name is \"Vitals\")" 2>/dev/null || echo 0)"
                [ "${WINDOWS:-0}" -ge 1 ] && break
                sleep 1
            done
            if [ "${WINDOWS:-0}" -ge 1 ]; then
                pass "launched and showed $WINDOWS Vitals window(s)"
            else
                fail "launched but never showed a Vitals window"
            fi

            # Quit that PID specifically, then wait for it to actually exit —
            # firing the quit and moving on let a broken bundle's process
            # outlive this run and poison the next one.
            osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to quit" >/dev/null 2>&1
            for _ in $(seq 1 10); do
                kill -0 "$PID" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "$PID" 2>/dev/null; then
                kill "$PID" 2>/dev/null || true
                for _ in $(seq 1 5); do
                    kill -0 "$PID" 2>/dev/null || break
                    sleep 1
                done
                kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
            fi
        fi
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "==> All checks passed"
else
    echo "==> VERIFICATION FAILED"
fi
exit "$FAILED"
