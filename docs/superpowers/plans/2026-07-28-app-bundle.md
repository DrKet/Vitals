# Distributable `.app` Bundle Implementation Plan (M2-A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Vitals from a SwiftPM executable into a double-clickable `Vitals.app`, published as a zip on a GitHub Release.

**Architecture:** `Package.swift` stays the single source of truth. `scripts/build-app.sh` assembles a bundle from `swift build -c release` output; `scripts/verify-app.sh` checks the produced artifact, including actually launching it and confirming a window appears. No Xcode project, no third-party tooling — only `swift`, `codesign`, `sips`, `iconutil`, `ditto`, `lipo` and `plutil`.

**Tech Stack:** Bash, Swift 6, AppKit/Core Graphics (icon rendering), macOS bundle format.

## Global Constraints

- **Platform floor:** macOS 26.0, matching `Package.swift`. Swift language mode 6.
- **No third-party dependencies.** Only tools shipped with macOS and Xcode.
- **Never fabricate a number.** Applied here to versioning: an untagged build reports `0.0.0-dev+<sha>`, never a release number nobody minted.
- **No paid Apple Developer account.** The bundle is ad-hoc signed (`codesign --sign -`). Gatekeeper *will* warn on download; that is documented, not hidden.
- **Verify the artifact, not the builder.** Every check runs against the produced bundle.
- **Swift build and test output must stay pristine** — no warnings. Check with a clean build: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`.
- **Scripts must be safe to re-run** and tolerate output from a previous run. Build scripts start `set -euo pipefail`. `verify-app.sh` is the deliberate exception: it uses `set -uo pipefail` **without `-e`**, because a verifier must run every check and report all failures rather than exiting at the first one. It signals failure through its exit code instead.

## Verified facts (measured before this plan was written — do not re-derive)

```
$ swift build -c release --arch arm64 --arch x86_64 --product VitalsApp
Build complete!

$ swift build -c release --arch arm64 --arch x86_64 --product VitalsApp --show-bin-path
/Users/george/Developer/Vitals/VitalsCore/.build/apple/Products/Release

$ lipo -archs .build/apple/Products/Release/VitalsApp
x86_64 arm64          # ~2.98 MB
```

**The universal binary lands in `.build/apple/Products/Release`, NOT `.build/release`.**
A script hardcoding `.build/release` picks up a stale single-arch binary or nothing.
Always resolve it with `swift build ... --show-bin-path`.

The spec's open question — whether a macOS 26 deployment target admits an
`x86_64` slice — is therefore **resolved: it does.**

## File Structure

| File | Responsibility |
|---|---|
| `scripts/make-icon.swift` | Renders the 1024pt icon artwork to PNG |
| `scripts/make-icon.sh` | Drives the renderer, builds the `.iconset`, packs the `.icns` |
| `scripts/build-app.sh` | Assembles, signs and zips `Vitals.app` |
| `scripts/verify-app.sh` | Checks the produced bundle, including a real launch |
| `VitalsCore/Sources/VitalsApp/VitalsApp.swift` | Modified — the `AppDelegate` shrinks |
| `README.md` | Modified — gains a Download section |

Build output goes to `build/` (git-ignored): `build/Vitals.app`, `build/Vitals-<version>.zip`.

---

### Task 1: The app icon

**Files:**
- Create: `scripts/make-icon.swift`
- Create: `scripts/make-icon.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `Resources/Vitals.icns`, committed to the repo. Task 2 copies it into the bundle.

The icon is committed rather than generated at build time: it changes almost never, and a build that depends on rendering artwork is a build with more ways to fail.

- [ ] **Step 1: Write the renderer**

Create `scripts/make-icon.swift`:

```swift
// Renders the Vitals app icon to a 1024x1024 PNG.
//
// Drawn from the app's own palette so the icon matches the UI rather than
// sitting beside it: the same dark surface the pages use, and a chart line
// like the ones the app actually draws.
//
// Run: swift scripts/make-icon.swift <output.png>
import AppKit

let side: CGFloat = 1024
// macOS icons supply their own rounded shape and are not masked by the system,
// so the artwork insets itself. ~10% margin matches Apple's own grid.
let margin: CGFloat = side * 0.10
let plate = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// Transparent outside the plate.
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()

// Squircle-ish plate. 22.37% of the plate's width is Apple's corner ratio.
let corner = plate.width * 0.2237
let platePath = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)
platePath.addClip()

// Vitals.Palette's surface, deepened toward the bottom.
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
    ending:   NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
)!
gradient.draw(in: plate, angle: -90)

// A chart line across the plate, in Vitals.Palette.cpu.
let points: [CGPoint] = [
    CGPoint(x: 0.10, y: 0.38), CGPoint(x: 0.22, y: 0.46), CGPoint(x: 0.32, y: 0.34),
    CGPoint(x: 0.43, y: 0.72), CGPoint(x: 0.54, y: 0.30), CGPoint(x: 0.65, y: 0.52),
    CGPoint(x: 0.78, y: 0.44), CGPoint(x: 0.90, y: 0.60),
].map { CGPoint(x: plate.minX + plate.width * $0.x, y: plate.minY + plate.height * $0.y) }

// Filled area beneath the line, echoing the app's stacked bands.
let area = NSBezierPath()
area.move(to: CGPoint(x: points[0].x, y: plate.minY))
points.forEach { area.line(to: $0) }
area.line(to: CGPoint(x: points[points.count - 1].x, y: plate.minY))
area.close()
NSColor(srgbRed: 0.49, green: 0.78, blue: 1.00, alpha: 0.22).setFill()
area.fill()

let line = NSBezierPath()
line.move(to: points[0])
points.dropFirst().forEach { line.line(to: $0) }
line.lineWidth = side * 0.035
line.lineCapStyle = .round
line.lineJoinStyle = .round
NSColor(srgbRed: 0.49, green: 0.78, blue: 1.00, alpha: 1).setStroke()
line.stroke()

image.unlockFocus()

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(2)
}
guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
```

- [ ] **Step 2: Write the packer**

Create `scripts/make-icon.sh`:

```bash
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
```

- [ ] **Step 3: Run it and verify the output**

```bash
chmod +x scripts/make-icon.sh && ./scripts/make-icon.sh
```

Expected: `wrote .../Resources/Vitals.icns`.

Then confirm all ten sizes actually landed — the check Task 3 automates:

```bash
iconutil --convert iconset Resources/Vitals.icns --output /tmp/check.iconset && ls /tmp/check.iconset | wc -l
```

Expected: `10`.

- [ ] **Step 4: Look at it**

```bash
qlmanage -t -s 512 -o /tmp Resources/Vitals.icns
```

Open `/tmp/Vitals.icns.png` and confirm it reads as a deliberate mark at a glance — a dark rounded plate with a blue chart line — not a blurry square or an empty plate. If it looks wrong, say so and describe what you see rather than shipping it.

- [ ] **Step 5: Ignore build output**

Add to `.gitignore`:

```
build/
```

- [ ] **Step 6: Commit**

```bash
git add scripts/make-icon.swift scripts/make-icon.sh Resources/Vitals.icns .gitignore
git commit -m "feat: add a generated app icon"
```

---

### Task 2: Assemble the bundle

**Files:**
- Create: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `Resources/Vitals.icns` from Task 1.
- Produces: `build/Vitals.app`. Task 3 verifies it; Task 5 zips it.

**Note:** the `AppDelegate` stays as-is in this task. Removing it is Task 4, gated on Task 3's launch test.

- [ ] **Step 1: Write the build script**

Create `scripts/build-app.sh`:

```bash
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
```

- [ ] **Step 2: Run it**

```bash
chmod +x scripts/build-app.sh && ./scripts/build-app.sh
```

Expected: ends with `==> Built .../build/Vitals.app  version 0.0.0-dev+<sha>  build <n>`.

The version will be the `dev` form unless a tag exists — that is correct, not a bug to work around.

- [ ] **Step 3: Confirm the bundle opens**

```bash
open build/Vitals.app
```

Expected: Vitals launches with a window, and its Dock icon is the one from Task 1 rather than a generic blank. Quit it afterwards.

If no window appears, stop and report — do not proceed to Task 3. That would mean the `Info.plist` is not doing what the `AppDelegate` currently does, which changes Task 4 entirely.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-app.sh
git commit -m "feat: assemble a signed Vitals.app from the package"
```

---

### Task 3: Verify the artifact

**Files:**
- Create: `scripts/verify-app.sh`
- Modify: `scripts/build-app.sh` (call it at the end)

**Interfaces:**
- Consumes: `build/Vitals.app` from Task 2.
- Produces: a pass/fail gate. Task 4 depends on the launch check to license removing the `AppDelegate` lines.

- [ ] **Step 1: Write the verifier**

Create `scripts/verify-app.sh`:

```bash
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
```

- [ ] **Step 2: Run it against the bundle from Task 2**

```bash
chmod +x scripts/verify-app.sh && ./scripts/verify-app.sh
```

Expected: every line `ok`, ending `==> All checks passed`.

- [ ] **Step 3: Prove the checks can fail**

A verifier that cannot fail is worse than none. Break three things, one at a time, confirm each is caught, then restore:

```bash
# 1. Wrong bundle identifier
plutil -replace CFBundleIdentifier -string com.wrong.Id build/Vitals.app/Contents/Info.plist
./scripts/verify-app.sh ; echo "exit=$?"      # expect FAIL on CFBundleIdentifier, exit=1

# 2. Truncated iconset
cp build/Vitals.app/Contents/Resources/Vitals.icns /tmp/good.icns
printf 'not an icns' > build/Vitals.app/Contents/Resources/Vitals.icns
./scripts/verify-app.sh ; echo "exit=$?"      # expect FAIL on icns, exit=1
cp /tmp/good.icns build/Vitals.app/Contents/Resources/Vitals.icns

# 3. Single-arch binary
lipo "build/Vitals.app/Contents/MacOS/Vitals" -thin arm64 -output /tmp/thin
cp /tmp/thin build/Vitals.app/Contents/MacOS/Vitals
./scripts/verify-app.sh ; echo "exit=$?"      # expect FAIL on universal, exit=1
```

Then rebuild clean and confirm green:

```bash
./scripts/build-app.sh && ./scripts/verify-app.sh ; echo "exit=$?"   # expect exit=0
```

Report what each broken run printed. If any of the three passes, that check is not doing its job — say so.

- [ ] **Step 4: Wire it into the build**

Append to `scripts/build-app.sh`:

```bash

echo
"$ROOT/scripts/verify-app.sh" "$APP"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-app.sh scripts/build-app.sh
git commit -m "feat: verify the built bundle, including that it shows a window"
```

---

### Task 4: Shrink the `AppDelegate`

**Files:**
- Modify: `VitalsCore/Sources/VitalsApp/VitalsApp.swift`

**Interfaces:**
- Consumes: `scripts/verify-app.sh`'s launch check from Task 3. That check is what licenses this change.

`AppDelegate` exists to call `setActivationPolicy(.regular)`, which a bundle's `Info.plist` provides. Its own comment says to remove it at this milestone. But it also carries `applicationShouldTerminateAfterLastWindowClosed`, and that must survive — this is a single-window utility and a lingering invisible process is the failure the delegate was added to fix.

- [ ] **Step 1: Remove the activation-policy lines**

In `VitalsCore/Sources/VitalsApp/VitalsApp.swift`, replace the `AppDelegate` with:

```swift
/// Quits when the window closes — this is a single-window utility, and a
/// lingering invisible process is a real failure mode this project has hit.
///
/// The activation policy that used to live here is now the bundle's job:
/// `Info.plist` makes this a normal windowed app, which is what a SwiftPM
/// executable could not do on its own. `scripts/verify-app.sh` launches the
/// built bundle and asserts a window appears, which is what proves that.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

- [ ] **Step 2: Confirm the package still builds clean**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

Expected: `0`. If `AppKit` is now unused in that file, remove the import; if it is still needed for `NSApplication`, keep it.

- [ ] **Step 3: Run the full test suite**

```bash
cd VitalsCore && swift test
```

Expected: all tests pass. Run it twice — this suite has a history of load-sensitive failures.

- [ ] **Step 4: Rebuild the bundle and verify**

```bash
./scripts/build-app.sh
```

Expected: `==> All checks passed`, including `ok    launched and showed 1 window(s)`.

**If the launch check now fails**, the `Info.plist` alone is not sufficient. Put the two lines back, re-run, and **record that finding** — it is worth keeping, not a step to retry quietly. Report it rather than working around it.

- [ ] **Step 5: Confirm `swift run` still works for developers**

The README tells people to build from source. That path has no bundle, so it relies on whatever the delegate does.

```bash
cd VitalsCore && swift run VitalsApp
```

Expected: **this may now launch without a visible window**, because nothing sets the activation policy outside a bundle. If so, that is a real regression for the documented build-from-source path — report it, and note that the README's "Running it" section may need to point at `./scripts/build-app.sh && open build/Vitals.app` instead. Do not silently leave a broken documented path.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsApp/VitalsApp.swift
git commit -m "refactor: let the bundle set the activation policy"
```

---

### Task 5: Package and document the download

**Files:**
- Modify: `scripts/build-app.sh` (zip step)
- Modify: `README.md`

**Interfaces:**
- Consumes: `build/Vitals.app` and the verifier from Tasks 2–3.
- Produces: `build/Vitals-<version>.zip`, ready to attach to a Release.

- [ ] **Step 1: Add the zip step**

In `scripts/build-app.sh`, after the verifier call, append:

```bash

ZIP="$OUT/Vitals-$VERSION.zip"
rm -f "$ZIP"
# ditto, not zip: a plain zip mangles a bundle's symlinks and resource forks.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> Packaged $ZIP"
```

- [ ] **Step 2: Build and confirm the zip round-trips**

```bash
REPO="$(pwd)"                       # run this from the repository root
"$REPO/scripts/build-app.sh"

rm -rf /tmp/ziptest && mkdir -p /tmp/ziptest
ditto -x -k "$REPO"/build/Vitals-*.zip /tmp/ziptest
"$REPO/scripts/verify-app.sh" /tmp/ziptest/Vitals.app
```

Expected: the extracted copy passes every check, including the signature. If `codesign --verify` fails on the extracted copy but passed on the original, the zip is mangling the bundle — report it.

- [ ] **Step 3: Add the README Download section**

Insert immediately after the screenshot in `README.md`, before `## Requirements`:

```markdown
## Download

Grab the latest `Vitals-<version>.zip` from
[Releases](https://github.com/DrKet/Vitals/releases), unzip, and move
`Vitals.app` to your Applications folder.

**macOS 26 or later is required.** On anything older the app will not launch.

### The first time you open it

Vitals is signed ad-hoc, not with a paid Apple Developer certificate, so
macOS will say:

> "Apple could not verify Vitals is free of malware."

That is Gatekeeper telling you the truth: this app has not been notarized by
Apple. To open it anyway, either:

- **right-click** `Vitals.app` → **Open** → **Open**, once; or
- run `xattr -dr com.apple.quarantine /Applications/Vitals.app`

You only need to do this once. If you would rather not, build from source
instead — the instructions below produce the same app.
```

- [ ] **Step 4: Reconcile the "Running it" section**

`README.md`'s "Running it" section currently says there is no `.app` bundle. That is now false. Update it to describe building one:

```bash
git clone https://github.com/DrKet/Vitals.git
cd Vitals
./scripts/build-app.sh
open build/Vitals.app
```

Keep `swift run vitals-dump` and `swift test`. If Task 4 Step 5 found that `swift run VitalsApp` no longer shows a window, remove it from the README rather than documenting a path that does not work.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-app.sh README.md
git commit -m "feat: package the app as a zip and document downloading it"
```

- [ ] **Step 6: Cut the release**

This publishes publicly, so **ask the project owner before running it** — including which version to tag.

```bash
git tag v0.1.0
./scripts/build-app.sh          # re-run so the version is the tag, not the dev form
gh release create v0.1.0 build/Vitals-v0.1.0.zip \
  --title "Vitals v0.1.0" \
  --notes "First downloadable build. Requires macOS 26 or later.

Vitals is signed ad-hoc, so the first launch needs a right-click → Open, or
\`xattr -dr com.apple.quarantine /Applications/Vitals.app\`. See the README.

Built: Overview, Processes, CPU, Memory, GPU, Storage and Network.
Not yet built: Sensors, Startup, Services, Users, History."
```

---

## Completion criteria

- `./scripts/build-app.sh` produces a signed, universal `build/Vitals.app` and a zip beside it.
- `./scripts/verify-app.sh` passes every check, and each check has been seen to fail when its target is broken.
- The app launches from the bundle with its own icon and a visible window.
- The extracted-from-zip copy verifies identically to the original.
- The README tells a downloader what they need, what warning they will see, and how to get past it.
- Swift build and test output remain warning-free.

## What comes next

The menu-bar extra and desktop widgets. Widgets will likely force the
Xcode-project question the spec deliberately deferred — a WidgetKit extension
needs a host bundle, which now exists, but wiring one up without an Xcode
project is the open question to answer then.
