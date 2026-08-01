# Visual Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four visual defects that all passed the 445-test suite — a chart
that eats the page, a crosshair readout that clips off the right edge, absolute
charts with no y-max, and a Processes cold start that reads as breakage.

**Architecture:** Four independent changes, no shared state between them, taken
in order 1-4. Item 1 is one token plus one modifier. Item 2 replaces a
measure-through-view-state mechanism with a one-subview `Layout`, keeping the
existing placement maths untouched. Item 3 adds a pure "nice bound" function
that both the scale and the new label read, so they cannot disagree. Item 4 adds
one conditional caption driven by a pure predicate.

**Tech Stack:** Swift 6 language mode, strict concurrency, macOS 26.0 floor,
SwiftUI, swift-testing (`@Test`/`@Suite`/`#expect`), no third-party
dependencies.

**Spec:** `docs/superpowers/specs/2026-08-01-visual-polish-design.md`

## Global Constraints

- **Never fabricate a number.** An unmeasurable value is `nil` and renders as
  "Unavailable" or an em dash — never `0`, never blank, never a guess. When you
  find yourself writing `?? 0`, stop.
- **Never trust a check you have not seen fail.** Every task below has an
  explicit "watch it go red" step. Do not skip it. Six tests on this project
  turned out to prove nothing.
- **Float equality is banned.** Compare with a tolerance. This project has been
  bitten four separate times.
- `swift test --filter` matches **type identifiers**, not `@Suite` display
  names. `--filter ChartGeometryTests` works; `--filter "Chart geometry"`
  matches zero tests **and still reports success**. A run saying "Test run with
  0 tests … passed" is a failed run.
- Warning checks need a clean build: `rm -rf .build && swift build
  --build-tests 2>&1 | grep -ci warning` must print `0`. An incremental build
  does not re-emit warnings for unchanged files.
- All commands run from `VitalsCore/` unless stated otherwise.
- Render tests need a **GUI login session** (a WindowServer connection). They
  fail under SSH-only.
- Branch is `visual-polish`, already created, spec already committed at 3a2ee4f.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/VitalsUI/Design/Tokens.swift` | Add `Metrics.chartMaxHeight` | 1 |
| `Sources/VitalsUI/Pages/HardwarePage.swift` | Apply the cap to its chart | 1 |
| `Tests/VitalsUITests/RenderHarness.swift` | Add `saturatedRowExtent` probe | 1 |
| `Tests/VitalsUITests/HardwarePageTests.swift` | Cap test at two window heights | 1 |
| `Sources/VitalsUI/Charts/ReadoutPlacement.swift` | **New.** One-subview `Layout` | 2 |
| `Sources/VitalsUI/Charts/MetricChart.swift` | Drop the PreferenceKey mechanism; draw the axis label | 2, 3 |
| `Tests/VitalsUITests/ReadoutPlacementTests.swift` | **New.** Overflow probe | 2 |
| `Sources/VitalsUI/Charts/ChartGeometry.swift` | `NiceBound`, `niceUpperBound`, `axisMaximum`, `axisLabel` | 3 |
| `Tests/VitalsUITests/ChartGeometryTests.swift` | Pure bound + label tests | 3 |
| `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift` | Cold-start caption + predicate | 4 |
| `Tests/VitalsUITests/ProcessesPageTests.swift` | Predicate + render tests | 4 |

---

## Task 1: Cap the chart's height on hardware pages

**Files:**
- Modify: `Sources/VitalsUI/Design/Tokens.swift:33-39` (the `Metrics` enum)
- Modify: `Sources/VitalsUI/Pages/HardwarePage.swift:95-101`
- Modify: `Tests/VitalsUITests/RenderHarness.swift` (append helper; also update
  the `chartCanvasProbeRegion` doc comment, which currently claims the chart
  grows without limit)
- Test: `Tests/VitalsUITests/HardwarePageTests.swift`

**Interfaces:**
- Produces: `Vitals.Metrics.chartMaxHeight: CGFloat` (220), and
  `saturatedRowExtent(in:region:minimumSpread:) throws -> ClosedRange<CGFloat>?`
  in the test harness. Nothing in Tasks 2-4 consumes either.

- [ ] **Step 1: Add the harness probe**

Append to `Tests/VitalsUITests/RenderHarness.swift`:

```swift
/// The vertical extent, in points, of saturated (non-grayscale) pixels inside
/// `region` — `nil` when the region is entirely neutral.
///
/// `regionHasSaturatedColor` answers "did the chart paint here at all". This
/// answers "how tall is what it painted", which is what a test of the chart's
/// *height* needs. Every hardware page's chrome — the offscreen material fill,
/// gridlines, `StatRow` text, the disclosure chevron — renders in neutral
/// greys (see `regionHasSaturatedColor`'s doc comment), so inside a page's
/// panel the saturated extent is the chart's own drawn height and nothing
/// else.
///
/// Returned in points, not pixels, by dividing through `image.scale` — the
/// same scale the bitmap itself reported, so a 1x and a 2x render give the
/// same answer.
@MainActor
func saturatedRowExtent(
    in image: RenderedImage,
    region: CGRect,
    minimumSpread: CGFloat = 16.0 / 255.0
) throws -> ClosedRange<CGFloat>? {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let minX = max(Int((region.minX * image.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * image.scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * image.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * image.scale).rounded(.up)), bitmap.pixelsHigh)
    guard minX < maxX, minY < maxY else { return nil }

    var top: Int?
    var bottom: Int?
    for y in minY..<maxY {
        for x in minX..<maxX {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
            if max(r, g, b) - min(r, g, b) > minimumSpread {
                if top == nil { top = y }
                bottom = y
                break
            }
        }
    }

    guard let top, let bottom else { return nil }
    return (CGFloat(top) / image.scale)...(CGFloat(bottom) / image.scale)
}
```

- [ ] **Step 2: Write the failing test**

Append inside `struct HardwarePageTests` in
`Tests/VitalsUITests/HardwarePageTests.swift`:

```swift
    /// The chart must stop growing at `Metrics.chartMaxHeight`, so the four
    /// pages with an empty `secondary` slot do not hand it half the window.
    ///
    /// Asserts across two window heights rather than against one absolute
    /// number: the defect this guards is *unbounded growth*, so the thing that
    /// must hold is that 300 extra points of window produce zero extra points
    /// of chart. A single-height assertion would pass against the old
    /// fill-everything behaviour at whichever height happened to be picked.
    ///
    /// The probe is the full panel width at both heights, and saturated pixels
    /// inside it can only come from the chart's own accent-tinted drawing —
    /// this fixture's `secondary` is neutral `Text`, and so is every other
    /// element on the page.
    @Test("the chart stops growing at the max-height token")
    func chartStopsGrowing() throws {
        let probe = CGRect(x: 40, y: 100, width: 720, height: 900)

        let short = try renderPNG(
            page(primaryValue: "13.9 GB", stats: []),
            size: CGSize(width: 800, height: 700),
            named: "hardware-page-cap-700"
        )
        let tall = try renderPNG(
            page(primaryValue: "13.9 GB", stats: []),
            size: CGSize(width: 800, height: 1000),
            named: "hardware-page-cap-1000"
        )

        let shortExtent = try #require(try saturatedRowExtent(in: short, region: probe))
        let tallExtent = try #require(try saturatedRowExtent(in: tall, region: probe))

        let shortHeight = shortExtent.upperBound - shortExtent.lowerBound
        let tallHeight = tallExtent.upperBound - tallExtent.lowerBound

        // Tolerance, never equality: these are measured pixel extents rounded
        // through a scale factor, and this project has been bitten four times
        // by exact float comparison.
        #expect(abs(tallHeight - shortHeight) < 2.0)
        #expect(tallHeight <= Vitals.Metrics.chartMaxHeight + 2.0)
    }
```

- [ ] **Step 3: Run it and watch it fail**

```bash
cd VitalsCore && swift test --filter HardwarePageTests 2>&1 | tail -20
```

Expected: a compile error, `Vitals.Metrics.chartMaxHeight` does not exist yet.
That is the first red. Proceed to Step 4, then return here: after Step 4 adds
the token but before Step 5 applies it, this test must fail on the
**assertions** — the tall render's chart will be roughly 300pt taller than the
short one. Confirm you see that assertion failure, not just the compile error.
A test that only ever failed to compile has not been seen to fail.

- [ ] **Step 4: Add the token**

In `Sources/VitalsUI/Design/Tokens.swift`, inside `public enum Metrics`, below
`chartHeight`:

```swift
        public static let chartHeight: CGFloat = 132
        /// The ceiling `HardwarePage` holds its chart to.
        ///
        /// `HardwarePage` pins its content stack to the window height so a
        /// trailing spacer has something to push against, and `MetricChart`
        /// declares `maxHeight: .infinity` so a tall tile shows more history.
        /// Together those made the chart the only greedy element on the page:
        /// on the four pages whose `secondary` slot is empty it took ~49% of a
        /// 713pt window and grew from there. The floor above is a guarantee;
        /// this is a limit. Deliberately not a fraction of window height —
        /// that would mean threading the container's geometry into the chart,
        /// widening `MetricChart`'s API for a layout concern that belongs to
        /// its caller.
        public static let chartMaxHeight: CGFloat = 220
```

Now re-run Step 3 and confirm the **assertion** failure described there.

- [ ] **Step 5: Apply the cap**

In `Sources/VitalsUI/Pages/HardwarePage.swift`, replace lines 95-101:

```swift
                            if !series.isEmpty {
                                MetricChart(
                                    series: series,
                                    style: .area(stacked: series.count > 1),
                                    colors: Vitals.seriesColors(startingAt: accent, count: max(series.count, 1))
                                )
                                // The cap lives here, not inside `MetricChart`:
                                // Overview tiles embed the same chart and size
                                // it from the tile's own geometry, and they do
                                // not have this problem. See
                                // `Metrics.chartMaxHeight`.
                                .frame(maxHeight: Vitals.Metrics.chartMaxHeight)
                            }
```

- [ ] **Step 6: Run the test and watch it pass**

```bash
cd VitalsCore && swift test --filter HardwarePageTests 2>&1 | tail -20
```

Expected: PASS, and the suite reports a non-zero test count.

- [ ] **Step 7: Update the now-stale harness comment**

`chartCanvasProbeRegion`'s doc comment in `RenderHarness.swift:150-165` says the
chart "grows past its `Vitals.Metrics.chartHeight` (132pt) floor to fill
leftover space … (207pt measured for CPU's, more for pages with no secondary
content below the chart)". The second half is no longer true. Replace that
parenthetical with:

```
/// (207pt measured for CPU's; every hardware page's is now held at or below
/// `Vitals.Metrics.chartMaxHeight` — 220pt — by `HardwarePage`)
```

The probe rectangle itself does not change: it stays within `y ∈ [111, 111+132]`,
which is inside the guaranteed floor and therefore unaffected by the cap.

- [ ] **Step 8: Run the whole suite**

```bash
cd VitalsCore && swift test 2>&1 | tail -15
```

Expected: 446 tests, 0 failures. If any *other* page's render test broke, the
cap moved content those tests probe by fixed coordinates — fix the probe, not
the cap, and say so in the commit.

- [ ] **Step 9: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Design/Tokens.swift VitalsCore/Sources/VitalsUI/Pages/HardwarePage.swift VitalsCore/Tests/VitalsUITests/RenderHarness.swift VitalsCore/Tests/VitalsUITests/HardwarePageTests.swift
git commit -m "fix: stop the chart from eating half of every hardware page"
```

---

## Task 2: Keep the crosshair readout inside the chart

**Files:**
- Create: `Sources/VitalsUI/Charts/ReadoutPlacement.swift`
- Modify: `Sources/VitalsUI/Charts/MetricChart.swift:27-34` (delete
  `ReadoutSizeKey`), `:56` (delete `readoutSize`), `:139-194` (the crosshair)
- Test: `Tests/VitalsUITests/ReadoutPlacementTests.swift` (new)

**Interfaces:**
- Consumes: `ChartGeometry.readoutOrigin(atX:in:boxSize:margin:)` — existing,
  unchanged, signature
  `(CGFloat, CGRect, CGSize, CGFloat = 8) -> CGPoint`.
- Produces: `ReadoutPlacement`, a `Layout` with one stored property
  `anchorX: CGFloat`. Nothing in Tasks 3-4 consumes it.

**Background the implementer needs.** The bug is *not* in `readoutOrigin`. That
function is correct and keeps every one of its existing tests in
`ChartScrubberTests.swift`. The bug is that `MetricChart` feeds it a `boxSize`
of `.zero`, because the size arrives through a `PreferenceKey` seeded at `.zero`
and the correction never lands — confirmed by holding a stationary cursor at a
chart's right edge for two seconds in the running app and watching the readout
stay clipped. A `Layout` gets the container bounds and can ask its subview for a
real size in the same call, so there is no first frame to be wrong on.

- [ ] **Step 1: Write the failing test**

Create `Tests/VitalsUITests/ReadoutPlacementTests.swift`:

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Readout placement")
struct ReadoutPlacementTests {

    /// The readout box, styled the way `MetricChart` styles it but with an
    /// opaque saturated fill so the probe can find it. Neutral chrome is
    /// invisible to `regionHasSaturatedColor`; a magenta box is not.
    private func box() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("24s ago")
            Text("Down  0.01 MB/s")
            Text("Up  0.10 MB/s")
        }
        .font(Vitals.Typography.label)
        .padding(6)
        .background(Vitals.Palette.legibilityAccent)
    }

    /// Rendered into a canvas WIDER than the chart the box is placed in, with
    /// the surplus left visible.
    ///
    /// This is the whole point of the test and the reason it cannot be
    /// vacuous. If the placement were probed inside a render exactly as wide
    /// as the chart, an overflowing box would be clipped by the image bounds
    /// and the probe would find nothing — passing for the broken code. Giving
    /// the render 200pt of visible surplus means an overflow has somewhere to
    /// land, and the assertion "nothing painted out there" has teeth.
    private func harness(anchorX: CGFloat) -> some View {
        HStack(spacing: 0) {
            ReadoutPlacement(anchorX: anchorX) { box() }
                .frame(width: 600, height: 200)
            Color.clear.frame(width: 200, height: 200)
        }
    }

    @Test("a readout anchored at the right edge stays inside the chart")
    func staysInsideAtRightEdge() throws {
        // 598 of a 600pt-wide chart: two points from the trailing edge, the
        // position that clips in the running app.
        let rendered = try renderPNG(
            harness(anchorX: 598),
            size: CGSize(width: 800, height: 200),
            named: "readout-right-edge"
        )

        // Nothing may paint in the surplus strip beyond the chart.
        let surplus = CGRect(x: 602, y: 0, width: 198, height: 200)
        #expect(try !regionHasSaturatedColor(in: rendered, region: surplus))

        // …and the box must actually have been drawn, or the assertion above
        // passes for a readout that rendered nothing at all.
        let inside = CGRect(x: 0, y: 0, width: 600, height: 200)
        #expect(try regionHasSaturatedColor(in: rendered, region: inside))
    }

    @Test("a readout anchored at the left edge stays inside the chart")
    func staysInsideAtLeftEdge() throws {
        let rendered = try renderPNG(
            harness(anchorX: 2),
            size: CGSize(width: 800, height: 200),
            named: "readout-left-edge"
        )
        let surplus = CGRect(x: 602, y: 0, width: 198, height: 200)
        #expect(try !regionHasSaturatedColor(in: rendered, region: surplus))
        #expect(try regionHasSaturatedColor(in: rendered, region: CGRect(x: 0, y: 0, width: 600, height: 200)))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd VitalsCore && swift test --filter ReadoutPlacementTests 2>&1 | tail -20
```

Expected: compile error, `ReadoutPlacement` does not exist. Proceed to Step 3.

- [ ] **Step 3: Write the Layout, deliberately broken first**

Create `Sources/VitalsUI/Charts/ReadoutPlacement.swift` with `.zero` hardcoded
where the measured size belongs — this reproduces the production bug inside the
new mechanism so you can watch the test catch it:

```swift
import SwiftUI

/// Places the crosshair's readout box inside a chart, clamped so it can never
/// overflow.
struct ReadoutPlacement: Layout {
    /// Where on the chart's x-axis the readout is reporting from.
    let anchorX: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = CGSize.zero   // DELIBERATELY WRONG — replaced in Step 5
        let origin = ChartGeometry.readoutOrigin(atX: anchorX, in: bounds, boxSize: size)
        subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(subview.sizeThatFits(.unspecified)))
    }
}
```

- [ ] **Step 4: Run it and watch it fail on the assertion**

```bash
cd VitalsCore && swift test --filter ReadoutPlacementTests 2>&1 | tail -20
```

Expected: `staysInsideAtRightEdge` FAILS on the surplus-strip expectation —
saturated pixels found beyond x=602. This is the production bug, reproduced and
caught. **Do not proceed until you have seen this exact failure.** If it passes
here, the test is vacuous and must be fixed before the implementation is.

- [ ] **Step 5: Fix it**

Replace the body of `placeSubviews`:

```swift
    /// The fix for the readout clipping off a chart's right edge.
    ///
    /// The placement maths (`ChartGeometry.readoutOrigin`) was never wrong; it
    /// was being handed a `boxSize` of `.zero`. `MetricChart` used to measure
    /// the box through a `PreferenceKey` seeded at `.zero` and feed the result
    /// back through `@State`, which meant the first hover positioned against a
    /// zero-width box — and, confirmed by holding a stationary cursor at a
    /// chart's right edge in the running app, never corrected afterwards.
    ///
    /// A `Layout` has no such first frame: `bounds` and
    /// `subviews[0].sizeThatFits(.unspecified)` are both available in this one
    /// call, so the clamp is computed against a real size the first time it is
    /// computed at all. No state, no preference, no second pass.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        let origin = ChartGeometry.readoutOrigin(atX: anchorX, in: bounds, boxSize: size)
        subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
```

- [ ] **Step 6: Run the test and watch it pass**

```bash
cd VitalsCore && swift test --filter ReadoutPlacementTests 2>&1 | tail -20
```

Expected: PASS, 2 tests.

- [ ] **Step 7: Wire it into MetricChart and delete the old mechanism**

In `Sources/VitalsUI/Charts/MetricChart.swift`:

1. Delete the whole `ReadoutSizeKey` declaration (lines 27-34, including its
   doc comment).
2. Delete `@State private var readoutSize: CGSize = .zero` (line 56).
3. Replace the readout portion of `crosshair(in:)` — everything from
   `VStack(alignment: .leading, spacing: 2) {` through
   `.onPreferenceChange(ReadoutSizeKey.self) { readoutSize = $0 }` — so the
   `ZStack` body reads:

```swift
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1)
                    .position(x: x, y: rect.midY)
                    .frame(height: rect.height)

                // Anchored to whichever side of the crosshair has more room and
                // clamped in both axes against the box's real size — see
                // `ReadoutPlacement`, which measures it during layout rather
                // than routing it back through view state.
                ReadoutPlacement(anchorX: x) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let timestamp = readout.timestamp {
                            Text(ChartGeometry.relativeAge(
                                of: timestamp,
                                now: ProcessInfo.processInfo.systemUptime
                            ))
                            .font(Vitals.Typography.label)
                            .foregroundStyle(.secondary)
                        }
                        ForEach(readout.values, id: \.name) { entry in
                            Text("\(entry.name)  \(unit(for: entry.name).formatted(entry.value))")
                                .font(Vitals.Typography.label)
                        }
                    }
                    .padding(6)
                    .glassSurface(cornerRadius: 8)
                }
            }
```

Also delete the now-orphaned `let origin = ChartGeometry.readoutOrigin(...)`
line above the `ZStack` — `ReadoutPlacement` computes it now.

- [ ] **Step 8: Run the whole suite**

```bash
cd VitalsCore && swift test 2>&1 | tail -15
```

Expected: 448 tests, 0 failures. `ChartScrubberTests`' `readoutOrigin` tests
must still pass untouched — if you had to change one, you changed the maths,
which this task must not do.

- [ ] **Step 9: Clean-build warning check**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

Expected: `0`. Deleting a `PreferenceKey` commonly leaves an unused import or
an unused variable behind, and an incremental build will not tell you.

- [ ] **Step 10: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Charts/ReadoutPlacement.swift VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift VitalsCore/Tests/VitalsUITests/ReadoutPlacementTests.swift
git commit -m "fix: stop the crosshair readout clipping off a chart's right edge"
```

---

## Task 3: Give absolute-unit charts a labelled, stable y-max

**Files:**
- Modify: `Sources/VitalsUI/Charts/ChartGeometry.swift:95-115` (`upperBound`)
  and append new members to the same `enum ChartGeometry`
- Modify: `Sources/VitalsUI/Charts/MetricChart.swift` (draw the label in
  `drawGridlines`' callers)
- Test: `Tests/VitalsUITests/ChartGeometryTests.swift`

**Interfaces:**
- Produces, all on `ChartGeometry`:
  - `struct NiceBound: Sendable, Equatable { let value: Double; let decimals: Int }`
  - `static func niceUpperBound(atLeast peak: Double) -> NiceBound`
  - `static func axisMaximum(for stacked: [[Double]], unit: ChartUnit) -> NiceBound?`
  - `static func axisLabel(_ bound: NiceBound, unit: ChartUnit) -> String?`
  - `static let absoluteFloor: Double` (0.001)
- `upperBound(for:unit:)` keeps its exact current signature. Existing callers
  and tests do not change.

**Why the bound changes and not just the label.** Today the bound *is* the peak,
so it moves every tick and the whole chart reshapes on steady traffic. A label
on a jittering bound would flicker between `41.25 MB/s` and `38.92 MB/s` — worse
than no label. Rounding up fixes both.

- [ ] **Step 1: Write the failing tests**

Append inside `struct ChartGeometryTests` in
`Tests/VitalsUITests/ChartGeometryTests.swift`:

```swift
    @Test("a nice upper bound rounds up to 1, 2 or 5 times a power of ten")
    func niceBoundRoundsUp() {
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 41.25).value - 50) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 0.12).value - 0.2) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 0.03).value - 0.05) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 10).value - 10) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 6).value - 10) < 1e-9)
    }

    /// The invariant that matters: a bound below the peak would clip real data,
    /// which is the same class of error as inventing it. Swept across five
    /// decades rather than spot-checked, because the failure mode is
    /// floating-point and floating-point failures hide between the cases
    /// anyone thinks to write by hand.
    @Test("a nice upper bound is never below the peak it must contain")
    func niceBoundNeverClips() {
        var peak = 0.001
        while peak < 10_000 {
            let bound = ChartGeometry.niceUpperBound(atLeast: peak)
            #expect(bound.value >= peak, "bound \(bound.value) is below peak \(peak)")
            peak *= 1.07
        }
    }

    /// `log10(0.001)` can land at -3.0000000000000004, whose floor is -4,
    /// producing a mantissa of 10.0 that a {1, 2, 5} multiplier list cannot
    /// cover. This is why the list has a 10 in it.
    @Test("the float-error case at an exact power of ten is covered")
    func niceBoundHandlesExactPowersOfTen() {
        for exponent in -4...4 {
            let peak = pow(10.0, Double(exponent))
            let bound = ChartGeometry.niceUpperBound(atLeast: peak)
            #expect(bound.value >= peak)
            #expect(abs(bound.value - peak) < peak * 1e-9, "\(peak) should already be nice")
        }
    }

    @Test("decimal places are derived from the bound's own exponent")
    func niceBoundDecimals() {
        #expect(ChartGeometry.niceUpperBound(atLeast: 41.25).decimals == 0)
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.12).decimals == 1)
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.03).decimals == 2)
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.001).decimals == 3)
        // 0.06 rounds to 0.1 — a 10x multiplier, so one decimal, not two.
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.06).decimals == 1)
    }

    @Test("fractional charts keep their 1.0 ceiling and get no label")
    func fractionalChartsAreUntouched() {
        let bands = [[0.2, 0.4, 0.37]]
        #expect(abs(ChartGeometry.upperBound(for: bands, unit: .fraction) - 1.0) < 1e-9)
        #expect(ChartGeometry.axisMaximum(for: bands, unit: .fraction) == nil)
    }

    /// A drift guard. The scale the renderer plots against and the number the
    /// label prints must come from the same computation, or the chart will one
    /// day say 50 while drawing against 41.25.
    @Test("the axis label's value is exactly the bound the chart plots against")
    func axisMaximumAgreesWithUpperBound() {
        let bands = [[0.01, 41.25, 3.0]]
        let unit = ChartUnit.absolute(suffix: "MB/s")
        let axis = ChartGeometry.axisMaximum(for: bands, unit: unit)
        #expect(abs(axis!.value - ChartGeometry.upperBound(for: bands, unit: unit)) < 1e-9)
    }

    @Test("an axis label prints its suffix at the derived precision")
    func axisLabelFormatting() {
        let unit = ChartUnit.absolute(suffix: "MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 41.25), unit: unit) == "50 MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 0.12), unit: unit) == "0.2 MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 0.001), unit: unit) == "0.001 MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 0.5), unit: .fraction) == nil)
    }
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd VitalsCore && swift test --filter ChartGeometryTests 2>&1 | tail -20
```

Expected: compile errors — `NiceBound`, `niceUpperBound`, `axisMaximum`,
`axisLabel` do not exist.

- [ ] **Step 3: Implement the bound**

`ChartGeometry.swift` currently imports only `CoreGraphics` and `SwiftUI`. The
code below needs `log10`, `pow` and `String(format:)`, so add `import Foundation`
at the top if the build complains — `ChartScrubber.swift`, in the same
directory, already does exactly that.

In `Sources/VitalsUI/Charts/ChartGeometry.swift`, add to `enum ChartGeometry`
above `upperBound`:

```swift
    /// The smallest positive bound an absolute-unit chart is allowed, so an
    /// all-zero or empty series still yields a non-degenerate range instead of
    /// dividing by zero.
    public static let absoluteFloor: Double = 0.001

    /// A chart ceiling, paired with the number of decimal places needed to
    /// print it exactly.
    ///
    /// The two travel together because the precision is a property of the
    /// bound's own exponent, not a formatting choice: 0.05 needs two decimals
    /// and 50 needs none, and deriving that twice in two places is how they
    /// drift apart.
    public struct NiceBound: Sendable, Equatable {
        public let value: Double
        public let decimals: Int
    }

    /// The smallest `m x 10^n` with `m` in `{1, 2, 5, 10}` that is at least
    /// `peak`.
    ///
    /// Absolute-unit charts used to scale to the raw peak, which meant the
    /// bound moved on every tick and the whole chart reshaped itself on steady
    /// traffic. Rounding up to a round number holds the scale still between
    /// samples *and* gives the reader a ceiling worth labelling — an idle link
    /// and a saturated one no longer draw the same picture.
    ///
    /// `10` is in the multiplier list deliberately. `log10`/`pow` round-tripping
    /// is not exact: `log10(0.001)` can land at `-3.0000000000000004`, whose
    /// floor is `-4`, giving a mantissa of `10.0` that `{1, 2, 5}` alone cannot
    /// cover. Returning the first candidate at or above `peak` is also what
    /// enforces the invariant that matters — a bound *below* the peak would
    /// clip a real measurement, which is the same class of error as inventing
    /// one.
    public static func niceUpperBound(atLeast peak: Double) -> NiceBound {
        guard peak > 0, peak.isFinite else {
            return NiceBound(value: absoluteFloor, decimals: 3)
        }

        let exponent = Int(floor(log10(peak)))
        // Paired with the extra power of ten a 10x multiplier carries, so the
        // decimal count never needs a float comparison against the multiplier.
        let steps: [(multiplier: Double, exponentShift: Int)] = [(1, 0), (2, 0), (5, 0), (10, 1)]

        for step in steps {
            let candidate = step.multiplier * pow(10.0, Double(exponent))
            if candidate >= peak {
                return NiceBound(
                    value: candidate,
                    decimals: max(0, -(exponent + step.exponentShift))
                )
            }
        }

        // Unreachable while `exponent == floor(log10(peak))`: the 10x candidate
        // is a full decade above the peak's own. Total rather than trapping,
        // because float error in `log10` is the reason this list has four
        // entries and not three.
        return NiceBound(value: 10 * pow(10.0, Double(exponent)), decimals: max(0, -(exponent + 1)))
    }
```

- [ ] **Step 4: Route `upperBound` through it, and add the label API**

Replace the `.absolute` branch of `upperBound(for:unit:)` (currently
`return max(peak, 0.001)`):

```swift
        case .absolute:
            // Through the same function `axisMaximum` uses, so the scale the
            // renderer plots against and the number the label prints cannot
            // disagree.
            return niceUpperBound(atLeast: max(peak, absoluteFloor)).value
```

Then append to `enum ChartGeometry`:

```swift
    /// The labelled ceiling for an absolute-unit chart, or `nil` for a
    /// fractional one.
    ///
    /// Fractional charts are bounded at 1.0 and CPU, Memory and GPU all show
    /// that as a headline percentage already — a "100%" label on the canvas
    /// would restate what the page says in 40pt type.
    public static func axisMaximum(for stacked: [[Double]], unit: ChartUnit) -> NiceBound? {
        guard case .absolute = unit else { return nil }
        let peak = stacked.flatMap { $0 }.max() ?? 0
        return niceUpperBound(atLeast: max(peak, absoluteFloor))
    }

    /// `bound` rendered with its unit suffix, or `nil` for a fractional chart.
    ///
    /// Deliberately not `ChartUnit.formatted`, whose `%.2f` would print a
    /// 0.001 ceiling as "0.00 MB/s" — a ceiling of zero on a chart that is
    /// visibly not flat.
    public static func axisLabel(_ bound: NiceBound, unit: ChartUnit) -> String? {
        guard case .absolute(let suffix) = unit else { return nil }
        return String(format: "%.\(bound.decimals)f %@", bound.value, suffix)
    }
```

- [ ] **Step 5: Run the tests and watch them pass**

```bash
cd VitalsCore && swift test --filter ChartGeometryTests 2>&1 | tail -20
```

Expected: PASS. Confirm the reported test count went up by 7.

- [ ] **Step 6: Prove `niceBoundNeverClips` can fail**

Temporarily change `if candidate >= peak` to `if candidate > peak * 1.5`, re-run
`--filter ChartGeometryTests`, and confirm `niceBoundNeverClips` and
`niceBoundRoundsUp` go red. Restore the line. Do not commit the broken version.

- [ ] **Step 7: Draw the label**

In `Sources/VitalsUI/Charts/MetricChart.swift`, inside the `Canvas` closure,
add a helper call after each `drawGridlines` call site. Add this method to
`MetricChart`:

```swift
    /// The y-max, drawn at the plot rect's top-leading corner.
    ///
    /// Absolute-unit charts only: they scale to their own data and would
    /// otherwise draw an idle link and a saturated one identically. Painted
    /// into the `Canvas`, so the crosshair overlay — a transient hover state on
    /// an opaque background — draws over it. That overlap is accepted; moving
    /// a transient readout to dodge a static label is not worth the coupling.
    private func drawAxisMaximum(
        _ bands: [[Double]],
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        let chartUnit = series.first?.unit ?? .fraction
        guard let bound = ChartGeometry.axisMaximum(for: bands, unit: chartUnit),
              let label = ChartGeometry.axisLabel(bound, unit: chartUnit) else { return }

        var text = context.resolve(Text(label).font(Vitals.Typography.label))
        text.shading = .color(.white.opacity(0.45))
        context.draw(text, at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: .topLeading)
    }
```

Call it immediately after `drawAreas(...)` in the `.area` case and after
`drawHistogram(...)` in the `.histogram` case, passing the same `bands` and the
same rect that case plotted into (`plotRect` for `.area`, `canvasRect` for
`.histogram`).

- [ ] **Step 8: Add the render assertion**

Append to `Tests/VitalsUITests/MetricChartTests.swift`, inside its suite:

```swift
    /// The label is text in a neutral grey, so `regionHasSaturatedColor` is
    /// the wrong probe — this uses `regionHasContent` against a corner of the
    /// canvas that gridlines alone would leave at the background colour.
    @Test("an absolute-unit chart labels its ceiling and a fractional one does not")
    func absoluteChartsDrawAnAxisLabel() throws {
        let absolute = MetricChart(
            series: [ChartSeries(name: "Down", values: [0.01, 0.4, 0.12], unit: .absolute(suffix: "MB/s"))],
            style: .area(stacked: false),
            colors: [Vitals.Palette.network]
        )
        let fractional = MetricChart(
            series: [ChartSeries(name: "Busy", values: [0.2, 0.4, 0.37])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu]
        )
        let corner = CGRect(x: 2, y: 0, width: 90, height: 18)

        let withLabel = try renderPNG(absolute, size: CGSize(width: 400, height: 200), named: "chart-axis-label")
        let without = try renderPNG(fractional, size: CGSize(width: 400, height: 200), named: "chart-no-axis-label")

        #expect(try regionHasContent(in: withLabel, region: corner))
        #expect(try !regionHasContent(in: without, region: corner))
    }
```

- [ ] **Step 9: Run the whole suite**

```bash
cd VitalsCore && swift test 2>&1 | tail -15
```

Expected: 456 tests, 0 failures. Pay attention to `StoragePageTests`,
`NetworkPageTests` and `OverviewPageTests`: they render absolute-unit charts and
their probe rectangles were tuned against the old peak-hugging scale. A band
that used to touch the canvas top now tops out lower — at 41.25 against a bound
of 50, that is 82% of the height. If one fails, the fixture's data or the probe
needs adjusting; the bound does not. Record which you changed and why.

- [ ] **Step 10: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Charts/ChartGeometry.swift VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift VitalsCore/Tests/VitalsUITests/ChartGeometryTests.swift VitalsCore/Tests/VitalsUITests/MetricChartTests.swift
git commit -m "feat: give absolute-unit charts a stable, labelled ceiling"
```

---

## Task 4: Explain the Processes cold start

**Files:**
- Modify: `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift:149-152` (body)
  and `:218-226` (below `header`)
- Test: `Tests/VitalsUITests/ProcessesPageTests.swift`

**Interfaces:**
- Consumes: `MetricsStore.processes: ProcessSeriesSample?` and its
  `cpuUsage: [pid_t: Double]` — both existing.
- Produces: `ProcessesPage.showsMeasuringNotice(for:) -> Bool`, `static`, pure.

- [ ] **Step 1: Write the failing tests**

Append inside `struct ProcessesPageTests`:

```swift
    @Test("the measuring notice shows only between a listing and its first rates")
    func measuringNoticeCondition() {
        // No listing at all: the page already says "No process listing
        // available." and must not also claim to be measuring.
        #expect(ProcessesPage.showsMeasuringNotice(for: nil) == false)

        // A listing with no rates yet — the 5-10s cold window this exists for.
        let cold = ProcessSeriesSample(
            processes: [Self.snapshot(1, "launchd", cpuTime: 12)],
            cpuUsage: [:]
        )
        #expect(ProcessesPage.showsMeasuringNotice(for: cold) == true)

        // Rates have landed. The notice must go on its own.
        let warm = ProcessSeriesSample(
            processes: [Self.snapshot(1, "launchd", cpuTime: 12)],
            cpuUsage: [1: 0.02]
        )
        #expect(ProcessesPage.showsMeasuringNotice(for: warm) == false)
    }
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd VitalsCore && swift test --filter ProcessesPageTests 2>&1 | tail -20
```

Expected: compile error, `showsMeasuringNotice` does not exist.

- [ ] **Step 3: Implement the predicate and the caption**

In `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift`, add to the struct:

```swift
    /// Whether to explain the column of em dashes a cold page shows.
    ///
    /// True only in the window between the first listing arriving and the
    /// first CPU rates being computable — `ProcessCPUTracker` needs two
    /// samples, so for roughly 5-10 seconds every rate is genuinely
    /// unmeasured. The dashes are correct and stay; this only says why.
    ///
    /// Keyed on the same `cpuUsage.isEmpty` condition the `onChange` handler
    /// in `body` already watches to re-sort, rather than a second notion of
    /// "cold" that could drift from it. A nil sample is excluded because that
    /// state has its own "No process listing available." message, and showing
    /// both would claim to be measuring something that was never listed.
    static func showsMeasuringNotice(for sample: ProcessSeriesSample?) -> Bool {
        guard let sample else { return false }
        return sample.cpuUsage.isEmpty
    }
```

Then change `body`'s `VStack` (line 149-152) to:

```swift
        return VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
            header
            if Self.showsMeasuringNotice(for: store.processes) {
                Text("Measuring — CPU and disk rates need a second sample.")
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
            }
            content(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
        }
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd VitalsCore && swift test --filter ProcessesPageTests 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Prove the predicate can fail**

Temporarily change `return sample.cpuUsage.isEmpty` to `return true`, re-run,
and confirm two of the three expectations go red. Restore it.

- [ ] **Step 6: Verify in the running app, not just the test**

```bash
cd ~/Developer/Vitals && ./scripts/build-app.sh && open build/Vitals.app
```

Select Processes immediately after launch. Confirm the caption is visible while
the rate columns show em dashes, and that it disappears once numbers appear —
without the table jumping in a way that looks broken. **Confirm through the
accessibility API which page is selected before describing what you saw**; an
agent on this project once reported a capture of a different page.

- [ ] **Step 7: Run the whole suite and the clean-build warning check**

```bash
cd VitalsCore && swift test 2>&1 | tail -15
```

Expected: 457 tests, 0 failures.

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

Expected: `0`.

- [ ] **Step 8: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessesPage.swift VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift
git commit -m "feat: explain the Processes cold start instead of showing bare dashes"
```

---

## Final verification

- [ ] **Whole suite, twice** — `swift test` run back to back, both green. A
  flaky render test that passes once is not passing.
- [ ] **Clean-build warning check** — `rm -rf .build && swift build
  --build-tests 2>&1 | grep -ci warning` prints `0`.
- [ ] **Look at the real app.** `./scripts/build-app.sh && open build/Vitals.app`.
  Walk CPU, Memory, GPU, Storage, Network and Processes. Confirm, page by page:
  the chart no longer dominates; the crosshair readout stays inside the chart at
  both extreme edges; Storage and Network show a y-max that does not flicker
  between ticks. Capture the window with `screencapture -R"$X,$Y,$W,$H"` after
  reading its bounds from System Events, and confirm the selected page through
  the accessibility API before describing any capture.
- [ ] **Update the ledger.** Append to `.superpowers/sdd/progress.md`: the four
  items, what each turned out to be, and anything that surprised you. Remove the
  three fixed entries from its "Known open items" list.
- [ ] **Update AGENTS.md.** Its "Known gaps" section lists all three of the
  chart-height, crosshair and y-axis items as open — remove them. Its claim that
  "The Overview has tiles for CPU and Memory only" is already stale as of
  c54df8d (it has all five); fix that line too.
