# Vitals — agent guide

A macOS system monitor: live CPU / memory / GPU / storage / network readings,
hardware detail pages, and (later) desktop widgets. Native SwiftUI, no
third-party dependencies.

Read this before changing anything. Most of it is hard-won — nearly every item
below is something that already went wrong here and cost a review round.

## The one rule that governs everything

**Never fabricate a number.**

An unmeasurable value is `nil`. It renders as "Unavailable" (`StatRow`) or an em
dash (`HardwarePage.displayPrimary`) — never `0`, never blank, never a plausible
guess. A series with no reading is **omitted from the chart**, never zero-filled:
a flat 0% band is a measurement the machine never reported.

This extends further than it first appears:

- A sampler that cannot produce a reading **throws**; it does not return an empty
  or zeroed result.
- A device or interface missing from a tick's dictionary means *no reading for
  that tick* — not zero. The throughput trackers omit it deliberately.
- Attributing a real measurement to the **wrong hardware** is the same class of
  error as inventing one. The GPU page withholds readings it cannot attribute
  rather than labelling them with a device name it cannot verify.
- It applies to the renderer too. A smoothing curve must not draw above or below
  the samples it interpolates — that is a value the machine never reported.

When you find yourself writing `?? 0`, stop.

Its corollary: **don't write an absence branch for a value that cannot be
absent.** Unreachable `?? "fallback"` on a non-optional input is dead code, and
it has had to be removed from three separate pages.

## Layout

```
VitalsCore/                     Swift package root — all code lives here
  Sources/
    SystemMetrics/              Mach/sysctl/IOKit sampling. No UI, no engine.
    MetricsEngine/              Actor scheduling samplers on cadences.
    VitalsUI/                   SwiftUI views, charts, design tokens.
      Charts/                   Pure chart maths + the Canvas renderer.
      Components/               Reusable pieces (StatRow, MetricTile, …).
      Design/Tokens.swift       Palette, metrics, typography, colour ramp.
      Pages/                    One file per sidebar page + HardwarePage.
      Shell/                    Window chrome, sidebar, routing.
    VitalsApp/                  The app executable.
    vitals-dump/                CLI for eyeballing live sampler output.
  Tests/                        One test target per source target.
docs/superpowers/specs/         The approved design spec. §6.2 is the hardware
                                page template, §6.3 the chart modes.
docs/superpowers/plans/         Implementation plans, one per milestone.
.superpowers/sdd/progress.md    Ledger: every task, decision and defect found.
                                Read this to understand why something is the
                                way it is.
```

Data flows one way: `SystemMetrics` → `MetricsEngine` → `MetricsStore` →
views. Nothing upstream knows about anything downstream.

## Build and test

```bash
cd VitalsCore
swift build
swift test
swift run vitals-dump   # live sampler output, no UI
```

To run the app itself, build the bundle rather than `swift run VitalsApp`: a
SwiftPM executable has no bundle, so AppKit launches it background-only with
zero windows (see Platform notes below).

```bash
./scripts/build-app.sh && open build/Vitals.app
```

Swift 6 language mode, strict concurrency, macOS 26.0 floor.

### Three commands that lie to you

**1. Warning checks need a clean build.**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

must print `0`. An incremental build does not re-emit warnings for unchanged
files, so a plain `swift build` after a successful one reports nothing
regardless of what is actually there. A real warning sat unreported for many
tasks because of this.

**2. `swift test --filter` matches type identifiers, not `@Suite` display
names.** `--filter MemoryPageTests` works; `--filter "Memory page"` matches zero
tests **and still reports success**. A run saying "Test run with 0 tests …
passed" is a failure to run. Seven filters in one plan matched nothing and
passed vacuously.

**3. Float equality.** This project has been bitten four separate times by
assertions like `0.2 + 0.1 == 0.3` that can never hold. Always compare with a
tolerance.

## Testing the UI — read this before writing a render test

Rendering is verified through a real off-screen `NSWindow` via `NSHostingView`
(`Tests/VitalsUITests/RenderHarness.swift`). **This needs a GUI session.**

Three separate times, a class of render assertion turned out to prove nothing:

- **`ImageRenderer` renders `.glassEffect` as nothing** — not the material, not
  even its child views. `glassSurface()` is therefore a switchable modifier keyed
  on the `vitalsGlassEnabled` environment value: the app gets real glass, the
  harness swaps equivalent geometry that captures. Don't add raw `.glassEffect`
  calls.
- **`ImageRenderer` renders `ScrollView`-rooted views blank.** Hence the
  `NSWindow` harness.
- **`regionHasContent` is vacuous inside a `GlassPanel`.** It compares against
  the corner pixel at (0,0), and the panel's material fill always differs from
  that, so it returns true no matter what drew. Use `regionHasSaturatedColor`
  for anything inside a panel.

A test you have not seen fail is a test you have not verified. Break the code
deliberately and confirm it goes red.

**Some things only screenshots catch.** Flat unreadable throughput charts, five
pages sharing one colour, and clipped chart peaks all passed the full suite and
were obvious on screen. To look:

```bash
./scripts/build-app.sh && open build/Vitals.app
```

`swift run VitalsApp` will not do here — it shows no window at all (see
Platform notes below), which makes it useless for a screenshot workflow.

Once it's running, get the window bounds via System Events and capture with
`screencapture -R"$X,$Y,$W,$H" out.png`. No Screen Recording permission needed.
**Confirm via the accessibility API which page is actually selected before
describing a screenshot** — an agent here once reported a capture that turned out
to be a different page.

## Conventions that are load-bearing

- **Series order.** The first series in a chart is the base band, is painted
  frontmost, and is the one the live dot marks. Memory is
  Wired/App/Compressed/Cached; GPU is Renderer/Tiler; Storage is Read/Write;
  Network is Down/Up. Reordering is a visible regression, not a refactor.
- **Charts carry a time axis.** Every `ChartSeries` built from store history must
  pass `timestamps:` alongside `values:`, or gap-breaking silently stops working
  for that page. Sampling is subscription-driven and stops when a page closes, so
  history genuinely does contain gaps; the chart breaks the line rather than
  drawing through.
- **Subscription-driven sampling.** Nothing is sampled unless a view subscribes,
  via `.task { await store.stream(_:) }`. SwiftUI's cancellation tears the
  subscription down; no manual bookkeeping.
- **`HardwarePage` owns the page chrome** — header, glass panels, stats block,
  sticky disclosure, tall-window fill, and chart style selection. A page supplies
  data and the two view-builder slots, nothing else. Reimplementing any of it is
  duplication.
- **Each page owns a hue.** `Vitals.seriesColors(startingAt:count:)` rotates the
  shared ramp so a page's chart leads with its own accent, matching its Overview
  tile. `Palette.warning` is deliberately kept out of the ramp.
- **Pages expose `static let disclosureKey`**, and `PageConsistencyTests` proves
  they're distinct. A duplicate makes two pages share one disclosure state.
- **Shared helpers exist — use them.** `Vitals.formatByteCount` (optional in,
  optional out) and `Vitals.formatKnownByteCount` (non-optional). Three separate
  private copies had to be removed. `ChartGeometry.sampleX` is the single source
  of truth for where sample *n* sits horizontally; the renderer and the crosshair
  both call it so they cannot drift.

## Platform notes worth knowing

- `host_page_size()` ≠ `vm_kernel_page_size`. The first is process-local; using
  it for kernel page counts gives a 4× error under Rosetta.
- `PROC_FLAG_TRANSLATED` does not exist in the SDK — use `P_TRANSLATED` on
  `kinfo_proc.kp_proc.p_flag`.
- Distinguish `ESRCH` from `EPERM` when walking processes, or every root process
  silently vanishes.
- Use `phys_footprint`, not RSS, for process memory.
- A SwiftPM executable has no bundle, so AppKit launches it background-only —
  `swift run VitalsApp` and the raw `.build/` binary both still do this. A
  bundled `.app` gets AppKit's default `.regular` activation policy for free;
  `AppDelegate` no longer sets it (that line came out once the bundle existed
  to provide it — see `VitalsApp.swift`). Outside a bundle the app runs with
  **zero windows** and every "it launches" check is meaningless.
- `AsyncStream.onTermination` does **not** fire on `break` out of a `for await`
  while the stream is still in scope. Drive teardown via task cancellation.

## Current state

Complete: the metrics foundation, the UI shell, the Overview (tiles for all
five series), the Processes table, the CPU, Memory, GPU, Storage and Network
pages, and a distributable `.app` bundle (v0.1.0).

Not built yet: the Sensors page (temperatures, fans and power all need
`IOHIDEventSystemClient`, a private framework needing an empirical spike);
desktop widgets and the menu-bar extra; a privileged helper for per-process
GPU, power and SMART health; and the Startup / Services / Users / History
pages.

Known gaps, if you're looking for something to pick up:

- The Processes table has no `selection:` binding. Every deferred slice of
  that milestone — context menu, inspector, tree view — needs one first.
- `ProcessComparator.compareValues` has a NaN/transitivity edge. Unreachable
  today, because nothing feeds it a NaN.

Worth knowing, but working as intended:

- Processes shows a column of em dashes for the first ~5-10s after a listing
  arrives, before `ProcessCPUTracker` has the two samples a rate needs. That
  is the honest reading of "not measured yet", and it is explained on-page by
  a caption — see `ProcessesPage.showsMeasuringNotice(for:)`.
- A hardware page's chart is capped at `Metrics.chartMaxHeight`, so a tall
  window leaves real empty space below the last panel rather than growing the
  chart without limit. Deliberate — see the token's doc comment.
