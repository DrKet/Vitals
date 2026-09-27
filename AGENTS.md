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
    ProcessControl/             Identity-checked Quit / Force Quit. Depends on
                                SystemMetrics only; the one module that acts.
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

### Four commands that lie to you

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

**4. An incremental build after adding a stored property produces a binary
that SIGSEGVs.** This is the explanation for the "HardwareProfile segfault"
that two milestones worked around without understanding.

Add a stored property to a public struct in `SystemMetrics`, run
`swift build --build-tests`, and it prints `Build complete!` in about three
seconds — far too fast to have rebuilt the test targets, which it hasn't. The
test binary keeps objects compiled against the old layout, and `swift test`
then dies with `exited with unexpected signal code 11`, in a **different test
each run**. `rm -rf .build` and the identical source passes.

Measured on Swift 6.3.3 / Xcode 26.6, from a clean baseline each time:

| Field added incrementally | Result          |
| ------------------------- | --------------- |
| `Bool`                    | clean, 6/6      |
| `String`                  | SIGSEGV, 5/5    |
| `BatteryHealth?`          | SIGSEGV, 6/6    |
| `BatteryHealth?`, but `rm -rf .build` first | clean, 5/5 |

The type dependence is what made this look like a defect specific to one
struct — it isn't. What matters is whether the new field is **refcounted**.
A `Bool` or `Int?` adds no reference, so the stale copy/destroy code still
retains and releases exactly the right set and stays accidentally correct
(it happens even though the struct's size and stride both change — 224/224
to 225/232 — so size is not the trigger). A `String`, or any struct
containing one, adds a reference the stale code does not know about, and the
crash is `EXC_BAD_ACCESS`, `KERN_INVALID_ADDRESS at 0x0`.

So: **after changing a public struct's stored properties, `rm -rf .build`
before you trust a test run.** A nondeterministic signal 11 across unrelated
tests is this, not a bug in whatever test happened to be running.

Two things this is *not*, both of which were suspected at the time: it is not
the `system_profiler` subprocess, and it is not machine load. Signal 11 kills
the run with no summary line at all; a `waitUntil` timeout (below) records an
issue and still prints a normal pass/fail summary.

**`waitUntil` timeouts are main-actor starvation, not load.** For a long time,
intermittent "Condition not met within 10 s" failures in `MetricsStoreTests`
were written off as a busy machine. Measured, each failing waiter had polled
only 5–6 times, across one ~8 s gap in which the main actor never ran — the
render probes, reading every pixel through `NSBitmapImageRep.colorAt` on the
main actor (~5 s for one full-page pass). The probes now read bytes through
`PixelGrid`, and `waitUntil` takes one last look after its deadline. If a
timeout comes back, measure the gap between polls before blaming load: one
multi-second gap means something synchronous is holding the main actor, and
`sample <test-pid>` during the stall will name it.

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

Pixel probes read raw bytes — through `PixelGrid`, or directly in
`isNotBlank`, which runs on the premultiplied in-memory capture — never
`colorAt(x:y:)` in a loop. Every render test runs on the main actor, and a
per-pixel `NSColor` over a page-sized region blocks it for seconds, starving
every other main-actor test in the parallel suite. The one deliberate
exception is `RenderHarnessTests.pixelGridMatchesColorAt`, whose small render
uses `colorAt` as the reference `PixelGrid` is checked against. Likewise, no
blocking sleep (`usleep`, `Thread.sleep`) in a main-actor test unless blocking
the main actor *is* the test (`WaitUntilTests`) — use `Task.sleep`.

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
- **Zombies read back as zeroes.** A process that has exited but not been
  reaped still appears in `KERN_PROC_ALL`, and `proc_pid_rusage` on it
  succeeds with a 0-byte footprint and zero CPU time. `ProcessSampler` skips
  `SZOMB` processes — re-checked *after* the rusage read, since a process can
  exit mid-scan — and gives them no identity. The intermittent `ProcessTests`
  "footprint … never zero" failure was this, not load.
- **`kill(2)` pid 0 is not `kernel_task`.** `kill(0, sig)` signals the
  caller's own process group, and a negative pid a whole group.
  `ProcessControl` refuses pid ≤ 0 before anything else; `KERN_PROC_PID` with
  pid 0 happily returns `kernel_task`, so an identity check alone does not
  catch it. It also refuses pid 1 (`launchd`, `.systemCritical`) as policy,
  so the rule holds even for a caller the kernel would allow.
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
- **There are two battery time estimates and they disagree.** The IORegistry's
  `TimeRemaining` (= `AvgTimeToEmpty`) is the raw gas gauge; IOPS's
  `kIOPSTimeToEmptyKey` / `kIOPSTimeToFullChargeKey` is what `pmset`, the menu
  bar and Settings read. Measured within one session on this machine: registry
  271 vs IOPS 505, and later registry 294 vs IOPS 164 — so they cross over,
  and neither is consistently the larger. They also sometimes agree exactly,
  which makes a single spot-check useless for telling which one you are
  reading. Vitals reads IOPS, so it cannot contradict the menu bar.
  The sharpest difference is in the first seconds on the adapter: IOPS
  reports `-1`, "still calculating", and `pmset` prints "(no estimate)", while
  the registry states a confident number. Any negative is unknown.
- **Plugged in and not charging is not the same as charged.** `IsCharging` No
  with `ExternalConnected` Yes happens at any charge level — macOS holds it
  for long stretches under optimised battery charging and calls it "AC
  attached; not charging". Use `FullyCharged` to tell the two apart;
  without it the page says "73% – Charged", which is a claim the machine
  never made.
- `AppleSmartBattery`'s `Amperage` is a signed value delivered unsigned:
  `4090` while charging, `18446744073709550565` while discharging (`-1051` in
  `UInt64` wraparound). A naive `Int64(raw)` read does not just produce a wrong
  number — it fatal-traps on the discharging value. Reinterpret with
  `Int64(bitPattern:)`. Only manifests on battery power, so it looks entirely
  correct on a machine that never left AC.

## Current state

Complete: the metrics foundation, the UI shell, the Overview (tiles for all
five series), the Processes table (with selection and a context menu: Copy
PID/Name, Reveal in Finder, confirmed Quit / Force Quit), the CPU, Memory,
GPU, Storage, Network, Sensors and Battery pages, and a distributable `.app`
bundle (v0.1.0).

The Sensors page shows temperatures only, and the reason matters if you are
thinking of adding fans.

The spike (`docs/superpowers/spikes/2026-08-02-sensors-spike.md`) did **not**
merely skip them. It swept **every** event type `0...63` across all 71 services
on usage page `0xff00`, and only two families answered at all: usage `0x0005`
(64 temperature sensors, event type `15`) and one service on `0x0004` stuck at
`0.000`. The two services on usage `0x000b` — a tempting match for this
machine's two fans — produce no event for any type in that range. So fans are
positively **not reachable through `IOHIDEventSystemClient`**; they need a
separate AppleSMC spike, not another pass over this API.

Component power is a different matter again: spec §4.6 routes it through the
IOReport Energy Model channel, an unrelated API the spike never touched.

`SensorReading.Kind` already models `.fanRPM` and `.powerWatts` for whenever
those land.

Not built yet: desktop widgets and the menu-bar extra; a privileged helper for
per-process GPU, power and SMART health; and the Startup / Services / Users /
History pages.

Known gaps, if you're looking for something to pick up:

- The Processes context menu covers Copy PID/Name, Reveal in Finder, Quit and
  Force Quit, on your own processes only. Suspend/Resume, renice, Sample,
  Spindump and Inspect are still to come; acting on root's or other users'
  processes needs the privileged helper. Add signal-based actions to
  `ProcessControl`, and keep every one of them behind its pid ≤ 1 refusals
  and its identity re-check.
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
