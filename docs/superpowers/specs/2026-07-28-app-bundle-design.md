# Distributable `.app` Bundle — Design

**Date:** 2026-07-28
**Milestone:** M2-A
**Status:** Approved

## Goal

Turn Vitals from a SwiftPM executable into a double-clickable `Vitals.app` that
can be downloaded from a GitHub Release and run.

Today, trying the app means cloning the repo and running `swift run VitalsApp`,
which needs Xcode and a Swift 6 toolchain. That is the single largest barrier
between the published repository and anyone actually testing it.

## Scope

The original spec's M2 bundles three things: the `.app`, a menu-bar extra, and
desktop widgets. The bundle is the foundation the other two need — a WidgetKit
extension must be hosted by a real app bundle — so it is its own milestone.

### Out of scope

- The menu-bar extra and desktop widgets
- Notarization (needs a paid Apple Developer account; see Decision 1)
- Auto-update
- A `.dmg` installer
- Migrating to an Xcode project

## Decisions

### 1. Ad-hoc signing, and honesty about Gatekeeper

No paid Apple Developer account is available, so the bundle is signed with
`codesign --force --sign -` — an ad-hoc signature. That is enough for macOS to
run the app locally; it is **not** enough for Gatekeeper.

A tester who downloads the zip gets a quarantine attribute on it, and
double-clicking produces *"Apple could not verify Vitals is free of malware."*

**The only honest response is to document the way through**, in both the README
and the release notes:

- right-click → **Open**, then confirm; or
- `xattr -dr com.apple.quarantine Vitals.app`

Pretending the warning is not there just produces confused messages. If a
Developer ID becomes available later, notarization slots into the same build
script as a submit-and-staple step.

### 2. A build script, not an Xcode project

`scripts/build-app.sh` assembles the bundle from `swift build` output.
`Package.swift` stays the single source of truth.

**Why not an Xcode project:** `.xcodeproj` is a merge-hostile generated blob
that would duplicate build settings currently living in `Package.swift`. It is
realistically what WidgetKit will want later — but that decision should be made
when widgets are actually being built, with real knowledge of what the extension
needs, rather than pre-emptively guessing now.

**Why not a Swift bundling tool:** it is about fifty lines of directory creation
and file copying. Wrapping that in a compiler to make it "testable in Swift"
is over-engineering; see Decision 3 for what actually gets tested.

### 3. Verify the artifact, not the builder

A shell script cannot be unit-tested in the style the rest of this codebase
uses. The bundle it produces can be, thoroughly — and that is the thing that
actually has to be correct.

`scripts/verify-app.sh` runs at the end of the build and is independently
runnable. See **Verification** below.

### 4. Universal binary

`swift build -c release --arch arm64 --arch x86_64`.

One flag, and it removes an entire class of "it will not launch" reports from
anyone on an Intel Mac. Costs a slower build and a roughly doubled binary — an
acceptable trade for a build whose purpose is being handed to other people.

**Resolved by measurement** before the implementation plan was written. A macOS
26 deployment target does admit an `x86_64` slice:

```
$ swift build -c release --arch arm64 --arch x86_64 --product VitalsApp
Build complete!
$ lipo -archs .build/apple/Products/Release/VitalsApp
x86_64 arm64            # ~2.98 MB
```

One gotcha found while checking: a universal build lands in
`.build/apple/Products/Release`, **not** `.build/release`. A script hardcoding
the usual path picks up a stale single-arch binary or nothing at all, so the
path must come from `swift build … --show-bin-path`.

### 5. Version derived, never declared

`CFBundleShortVersionString` comes from `git describe --tags`, falling back to
`0.0.0-dev+<short-sha>` when there is no tag.

An untagged working build therefore says plainly that it is a working build
rather than claiming a release number nobody minted. This is the same instinct
as the rest of the app: do not state something you have not got.

`CFBundleVersion` gets the commit count — monotonic, which is what macOS
expects of it.

## Bundle layout

```
Vitals.app/Contents/
  Info.plist
  MacOS/Vitals            ← the release binary, renamed from VitalsApp
  Resources/Vitals.icns
  _CodeSignature/         ← written by codesign
```

### `Info.plist` keys

| Key | Value |
|---|---|
| `CFBundleName` / `CFBundleDisplayName` | `Vitals` |
| `CFBundleIdentifier` | `com.drket.Vitals` |
| `CFBundleExecutable` | `Vitals` |
| `CFBundleIconFile` | `Vitals` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` | derived — Decision 5 |
| `CFBundleVersion` | commit count |
| `LSMinimumSystemVersion` | `26.0` — matches `Package.swift`'s floor, so a Mac too old to run it says so rather than crashing |
| `NSHighResolutionCapable` | `true` |
| `LSApplicationCategoryType` | `public.app-category.utilities` |

## The `AppDelegate` comes out

`VitalsApp.swift` carries an `AppDelegate` whose own comment says *"Remove this
when the app gains a real bundle in M2."* It exists to call
`setActivationPolicy(.regular)`, which a bundle's `Info.plist` provides for
free — without it, a SwiftPM executable launches background-only and builds its
scene without ever showing a window.

But the delegate also carries
`applicationShouldTerminateAfterLastWindowClosed`, and that behaviour must
survive: this is a single-window utility, and a lingering invisible process is
precisely the failure the delegate was added to fix.

**So the delegate shrinks to that one method rather than being deleted.**

The sequence is explicit, because the order is what makes it safe:

1. Remove the `setActivationPolicy` / `activate` lines, keeping
   `applicationShouldTerminateAfterLastWindowClosed`.
2. Build the bundle and run the launch test.
3. If a window appears, the `Info.plist` is genuinely doing the job and the
   lines stay out.
4. If no window appears, put them back and record in the ledger that the
   bundle alone was not sufficient — that is a finding worth keeping, not a
   failed step to retry quietly.

Getting this wrong reproduces a real bug from this project's history: the app
ran perfectly and invisibly for three milestones because nothing verified a
window existed.

## Icon

A small Swift script renders a 1024×1024 PNG with Core Graphics — a rounded
square with a dark gradient and a chart line across it, drawn from
`Vitals.Palette` so the icon matches the app rather than sitting beside it.
`sips` then downscales into the ten required `.iconset` entries and
`iconutil -c icns` packs them.

It is a clean placeholder mark, not a designed logo. Replacing it later means
swapping one PNG and re-running.

Required sizes: 16, 32, 64, 128, 256, 512, 1024 — as `icon_16x16`,
`icon_16x16@2x`, `icon_32x32`, `icon_32x32@2x`, `icon_128x128`,
`icon_128x128@2x`, `icon_256x256`, `icon_256x256@2x`, `icon_512x512`,
`icon_512x512@2x`.

## Distribution

`ditto -c -k --sequesterRsrc --keepParent Vitals.app Vitals-<version>.zip`.

`ditto` rather than `zip`: a plain `zip` mangles a bundle's symlinks and
resource forks. The zip attaches to a tagged GitHub Release, whose notes carry
the Gatekeeper instructions from Decision 1.

## Verification

`scripts/verify-app.sh`, run at the end of `build-app.sh` and independently
runnable:

- `Contents/MacOS/Vitals` exists and is executable
- `lipo -archs` reports **both** `arm64` and `x86_64`
- `Info.plist` parses, and `CFBundleIdentifier`, `CFBundleExecutable`,
  `LSMinimumSystemVersion` and a non-empty `CFBundleShortVersionString` are all
  what they should be
- the `.icns` contains **all ten** sizes — a truncated iconset is a classic
  silent failure
- `codesign --verify --strict` passes
- **the launch test**: open the bundle, poll System Events for a window, assert
  at least one appeared, then quit

The launch test is the important one. It is what proves the bundle works, and
it is what licenses removing the activation-policy line — the two are the same
check.

## README

Gains a **Download** section: the release link, the macOS 26 requirement stated
*before* someone downloads rather than after it fails, and the Gatekeeper steps.

The existing "Running it" section stays for people building from source.

## Constraints inherited from the project

- **Never fabricate a number.** Decision 5 is this rule applied to versioning.
- Platform floor macOS 26.0; Swift 6, language mode 6.
- No third-party dependencies. The build uses only tools shipped with macOS and
  Xcode: `swift`, `codesign`, `sips`, `iconutil`, `ditto`, `lipo`, `plutil`.
- Build and test output pristine — no warnings, verified from a clean build.
