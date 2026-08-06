# Overview bar+spark tiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Overview so its tiles carry a proportion bar and a sparkline, the grid never collapses into the single full-height row that is the bug today, and Battery appears as a sixth tile on machines that have one.

**Architecture:** Three small, independently-tested changes plus one assembly task. `TileLayout.columnCount` gains a column cap (the actual fix for the tallness); `MetricTile` gains an optional proportion bar; `OverviewPage` gains pure helpers for the GPU/Memory fractions and the tile ordering; then `TileGrid` and `OverviewPage` are wired together with a height-cap token and conditional Battery.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency), SwiftUI, Swift Testing (`@Test`/`@Suite`/`#expect`), macOS 26 floor. Tests render through the off-screen `NSWindow` harness in `Tests/VitalsUITests/RenderHarness.swift`.

## Global Constraints

- **Never fabricate a number.** An unmeasurable value is `nil` and renders as absence, never `0`. A proportion bar is a claim about a denominator, so it appears only where a real whole exists (CPU load, Memory used, GPU utilisation, Battery charge) and never for throughput. It also disappears when the value itself is unmeasured — never a zero-length bar.
- **Swift 6 language mode, strict concurrency, macOS 26.0 floor.**
- **Warning checks need a clean build.** `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`. An incremental build does not re-emit warnings.
- **`swift test --filter` matches type identifiers, not `@Suite` display names.** Use the test *type* name (e.g. `TileLayoutTests`), never the quoted suite title.
- **Float equality is forbidden.** Compare with a tolerance (`abs(a - b) < 1e-9`).
- **Render tests need a GUI session** and use `regionHasSaturatedColor` (not `regionHasContent`) for anything inside a `GlassPanel`, because the panel's material fill always differs from the image corner. Break the code and watch the test go red before trusting it.
- **Build/test commands:** `cd VitalsCore && swift build` / `swift test` / `swift test --filter <TypeName>`. Visual check: `./scripts/build-app.sh && open build/Vitals.app` (a bundled `.app`, never `swift run VitalsApp`, which shows no window).

---

### Task 1: Column cap on `TileLayout.columnCount`

The actual fix for the tallness. Capping the column count at three forces five or six tiles into at least two rows, so no single row can ever fill the whole window height.

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/Components/TileLayout.swift:16-24`
- Test: `VitalsCore/Tests/VitalsUITests/TileLayoutTests.swift`

**Interfaces:**
- Produces: `TileLayout.columnCount(width:minimumTileWidth:spacing:maximum:) -> Int`, where `maximum: Int = .max`. The cap only ever lowers the width-derived count. Existing three-argument callers are unaffected by the default.

- [ ] **Step 1: Write the failing tests**

Add to `VitalsCore/Tests/VitalsUITests/TileLayoutTests.swift`, inside the existing `@Suite("Tile layout")` struct:

```swift
@Test("the column count is capped when a maximum is given")
func maximumCapsTheColumnCount() {
    // Width 1248 fits exactly five 240pt tiles with 12pt gaps
    // (5*240 + 4*12 = 1248), so the uncapped count is five.
    #expect(TileLayout.columnCount(width: 1248, minimumTileWidth: 240, spacing: 12) == 5)
    // The cap forces that down to three — the rule that keeps five or six
    // tiles from ever forming a single full-height row.
    #expect(TileLayout.columnCount(width: 1248, minimumTileWidth: 240, spacing: 12, maximum: 3) == 3)
}

@Test("the maximum only ever lowers, never raises, the fitted count")
func maximumNeverRaises() {
    // Width 492 fits only two tiles; a maximum of three must not invent a
    // third column where the width cannot hold one.
    #expect(TileLayout.columnCount(width: 492, minimumTileWidth: 240, spacing: 12, maximum: 3) == 2)
}

@Test("a maximum still respects the one-column floor")
func maximumKeepsTheOneColumnFloor() {
    // A degenerate width floors at one column; the cap cannot push it below.
    #expect(TileLayout.columnCount(width: 0, minimumTileWidth: 240, spacing: 12, maximum: 3) == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd VitalsCore && swift test --filter TileLayoutTests`
Expected: FAIL to compile — `columnCount` has no `maximum:` argument.

- [ ] **Step 3: Add the `maximum` parameter**

Replace `VitalsCore/Sources/VitalsUI/Components/TileLayout.swift:16-24` with:

```swift
    public static func columnCount(
        width: CGFloat,
        minimumTileWidth: CGFloat,
        spacing: CGFloat,
        maximum: Int = .max
    ) -> Int {
        guard width > 0, minimumTileWidth > 0 else { return 1 }
        let fitted = Int((width + spacing) / (minimumTileWidth + spacing))
        return min(max(fitted, 1), maximum)
    }
```

Also extend the doc comment above it (currently "How many tiles fit across `width`, never fewer than one.") with a line:

```swift
    /// How many tiles fit across `width`, never fewer than one and never more
    /// than `maximum`. The cap only lowers the fitted count — it is what keeps
    /// five or six tiles from collapsing into a single full-height row on a
    /// wide window.
    ///
    /// Solves `n * minimum + (n - 1) * spacing <= width` for `n`.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd VitalsCore && swift test --filter TileLayoutTests`
Expected: PASS (all cases, including the pre-existing ones).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/Components/TileLayout.swift VitalsCore/Tests/VitalsUITests/TileLayoutTests.swift
git commit -m "feat: cap TileLayout.columnCount at an optional maximum

The width-derived column count, capped, is what stops five or six tiles
from ever forming the single full-height row that makes the Overview tiles
grow to fill the whole window. Additive: the default maximum of .max leaves
every existing caller unchanged."
```

---

### Task 2: Proportion bar on `MetricTile`

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/Components/MetricTile.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MetricTileTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `MetricTile.init(label:value:accent:fraction:series:)` with `fraction: Double? = nil` inserted before `series`. When non-nil, the tile draws a proportion bar between the value and the sparkline; when nil, the tile is byte-for-byte the current label/value/chart tile.

- [ ] **Step 1: Write the failing tests**

Add to `VitalsCore/Tests/VitalsUITests/MetricTileTests.swift`, inside `@Suite("Metric tile")`:

```swift
@Test("a tile with a fraction draws a proportion bar")
func fractionDrawsBar() throws {
    // Empty series so the ONLY saturated content the tile can draw is the
    // bar's accent fill — the label and value are neutral/white. That
    // isolates "is there a bar?" to a whole-tile saturation probe, with no
    // pixel-precise coordinates to drift.
    let tile = MetricTile(
        label: "CPU", value: "50%", accent: Vitals.Palette.cpu,
        fraction: 0.5, series: []
    )
    let image = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-bar-present")
    #expect(try regionHasSaturatedColor(in: image, region: CGRect(x: 0, y: 0, width: 260, height: 150)))
}

@Test("a tile with no fraction draws no bar")
func noFractionNoBar() throws {
    // The never-fabricate rule for the bar: no whole, no bar. With an empty
    // series and a nil fraction, nothing saturated is drawn at all.
    let tile = MetricTile(
        label: "Storage", value: "5.28 MB/s", accent: Vitals.Palette.storage,
        fraction: nil, series: []
    )
    let image = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-bar-absent")
    #expect(try !regionHasSaturatedColor(in: image, region: CGRect(x: 0, y: 0, width: 260, height: 150)))
}
```

The whole-tile probe works because the harness renders `GlassPanel` as
`.regularMaterial` (neutral grey) and the label/value text is white or grey
(also neutral) — only the accent bar is saturated. If `noFractionNoBar` is
unexpectedly red (the material or text registers as saturated on your machine),
narrow both probes to the horizontal band just under the value where the bar
sits — e.g. `CGRect(x: 20, y: 70, width: 220, height: 12)` — rather than the
whole tile. The band still isolates the bar (the chart area is empty here).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd VitalsCore && swift test --filter MetricTileTests`
Expected: FAIL to compile — `MetricTile.init` has no `fraction:` argument.

- [ ] **Step 3a: Add the parameter WITHOUT drawing the bar (compile, still red on the present-case)**

In `VitalsCore/Sources/VitalsUI/Components/MetricTile.swift`, add a stored property and init parameter. Change the property block (currently `label`, `value`, `accent`, `series`) and the initializer:

```swift
    private let label: String
    private let value: String?
    private let accent: Color
    private let fraction: Double?
    private let series: [ChartSeries]

    public init(label: String, value: String?, accent: Color, fraction: Double? = nil, series: [ChartSeries]) {
        self.label = label
        self.value = value
        self.accent = accent
        self.fraction = fraction
        self.series = series
    }
```

- [ ] **Step 3b: Run to confirm the present-case is red for the right reason**

Run: `cd VitalsCore && swift test --filter MetricTileTests`
Expected: `fractionDrawsBar` FAILS (no saturated colour — the bar is not drawn yet); `noFractionNoBar` and the two pre-existing tests PASS. This proves the present-case test detects a missing bar rather than a compile error.

- [ ] **Step 3c: Draw the bar**

Add this private view at the bottom of `MetricTile.swift`, inside the file but outside the `MetricTile` struct:

```swift
/// The Overview tile's proportion bar: a track with an accent fill sized to
/// `fraction`. Shown only when the metric is a real fraction of a known whole —
/// see `MetricTile`'s `fraction` parameter. A plain accent fill, not the
/// Battery page's warning-aware `BatteryLevelBar`: the Overview is a glance
/// surface and the tile's own value carries the number.
private struct ProportionBar: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                // Clamped, never fabricated: a reading cannot exceed its whole,
                // but clamping keeps a stray value from overflowing the track.
                Capsule().fill(accent)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
```

Then in `MetricTile.body`, insert the bar between the value `Text` and the chart `if`. The `VStack` currently reads:

```swift
                Text(Self.displayValue(value))
                    .font(Vitals.Typography.tileValue)
                    .foregroundStyle(value == nil ? .secondary : .primary)

                if series.contains(where: { !$0.values.isEmpty }) {
```

Insert the bar so it becomes:

```swift
                Text(Self.displayValue(value))
                    .font(Vitals.Typography.tileValue)
                    .foregroundStyle(value == nil ? .secondary : .primary)

                if let fraction {
                    ProportionBar(fraction: fraction, accent: accent)
                }

                if series.contains(where: { !$0.values.isEmpty }) {
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd VitalsCore && swift test --filter MetricTileTests`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/Components/MetricTile.swift VitalsCore/Tests/VitalsUITests/MetricTileTests.swift
git commit -m "feat: draw a proportion bar on MetricTile when given a fraction

A bar is a claim about a denominator, so it appears only when the tile is
handed a real fraction of a known whole and is absent otherwise — the
never-fabricate rule at the presentation layer. Additive: fraction defaults
to nil, so the tile is unchanged until a caller opts in."
```

---

### Task 3: `OverviewPage` fraction and ordering helpers

Pure, directly-tested seams for the two decisions with real logic — the GPU attribution gate on the fraction, and which tiles exist — plus the Memory fraction's divide-by-zero guard.

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift`
- Test: `VitalsCore/Tests/VitalsUITests/OverviewPageTests.swift`

**Interfaces:**
- Consumes: `GPUPage.attributableLatest(_:gpuCount:sampleCount:) -> GPUSample?` (existing).
- Produces:
  - `OverviewPage.gpuTileFraction(sample: GPUSample?, gpuCount: Int, sampleCount: Int) -> Double?`
  - `OverviewPage.memoryFraction(usedBytes: UInt64?, totalBytes: UInt64?) -> Double?`
  - `OverviewPage.tileOrder(hasBattery: Bool) -> [String]`

- [ ] **Step 1: Write the failing tests**

Add to `VitalsCore/Tests/VitalsUITests/OverviewPageTests.swift`, inside `@Suite("Overview page")`:

```swift
// MARK: Tile fractions — the proportion bar's value, gated exactly like the tile

@Test("the GPU tile fraction is the attributable device utilisation, or nil")
func gpuTileFractionMirrorsTheValueGate() {
    // Same gate as gpuTileValue: a single attributable GPU yields its raw
    // device utilisation (0.42), and every ambiguous case yields nil so the
    // bar is absent exactly when the value is.
    #expect(OverviewPage.gpuTileFraction(sample: Self.sample, gpuCount: 1, sampleCount: 1)
            .map { abs($0 - 0.42) < 1e-9 } == true)
    #expect(OverviewPage.gpuTileFraction(sample: Self.sample, gpuCount: 2, sampleCount: 1) == nil)
    #expect(OverviewPage.gpuTileFraction(sample: Self.sample, gpuCount: 1, sampleCount: 2) == nil)
    #expect(OverviewPage.gpuTileFraction(sample: nil, gpuCount: 1, sampleCount: 1) == nil)
}

@Test("the memory fraction guards a missing or zero total, never dividing by zero")
func memoryFractionGuardsTheTotal() {
    #expect(OverviewPage.memoryFraction(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
            .map { abs($0 - 0.5) < 1e-9 } == true)
    // A total the machine could not report is not a whole to be a fraction of.
    #expect(OverviewPage.memoryFraction(usedBytes: 8_000_000_000, totalBytes: nil) == nil)
    #expect(OverviewPage.memoryFraction(usedBytes: 8_000_000_000, totalBytes: 0) == nil)
    // No used reading yet is likewise nil, not a fabricated zero.
    #expect(OverviewPage.memoryFraction(usedBytes: nil, totalBytes: 16_000_000_000) == nil)
}

@Test("Battery is a tile only on a machine that has one")
func batteryTileIsConditional() {
    let withBattery = OverviewPage.tileOrder(hasBattery: true)
    let without = OverviewPage.tileOrder(hasBattery: false)
    #expect(withBattery.contains("battery"))
    #expect(withBattery.count == 6)
    #expect(without.contains("battery") == false)
    #expect(without.count == 5)
    // The five base tiles keep their established order in both cases.
    #expect(Array(withBattery.prefix(5)) == ["cpu", "memory", "gpu", "storage", "network"])
    #expect(without == ["cpu", "memory", "gpu", "storage", "network"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd VitalsCore && swift test --filter OverviewPageTests`
Expected: FAIL to compile — `gpuTileFraction`, `memoryFraction`, and `tileOrder` do not exist.

- [ ] **Step 3: Add the three helpers**

In `VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift`, add these `static` methods (place them beside the existing `gpuTileValue`, in the `// MARK: GPU` region and a new grouping — keep each near its subject):

```swift
    /// The Overview GPU tile's bar value: the attributable device utilisation,
    /// or `nil`. Mirrors `gpuTileValue`'s gate exactly — the raw fraction the
    /// value formats as a percentage — so the bar is present precisely when the
    /// value is, and never attributes one GPU's load under a generic label on a
    /// multi-GPU Mac.
    static func gpuTileFraction(sample: GPUSample?, gpuCount: Int, sampleCount: Int) -> Double? {
        GPUPage.attributableLatest(sample, gpuCount: gpuCount, sampleCount: sampleCount)?.deviceUtilisation
    }

    /// The Memory tile's bar value: used over total, or `nil` when there is no
    /// total to be a fraction of. Guards `total > 0` for the same reason the
    /// memory series does — a machine that cannot report `hw.memsize` has no
    /// whole, and dividing by it would be a fabricated proportion.
    static func memoryFraction(usedBytes: UInt64?, totalBytes: UInt64?) -> Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// The tiles the Overview shows, in order. Battery is appended only on a
    /// machine that has one — six tiles divide into a clean grid where five
    /// leave a gap, but a desktop Mac has no battery to show. The body builds
    /// its tiles from exactly this list, so presence lives in one tested place.
    static func tileOrder(hasBattery: Bool) -> [String] {
        ["cpu", "memory", "gpu", "storage", "network"] + (hasBattery ? ["battery"] : [])
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd VitalsCore && swift test --filter OverviewPageTests`
Expected: PASS (new and pre-existing).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift VitalsCore/Tests/VitalsUITests/OverviewPageTests.swift
git commit -m "feat: add Overview tile fraction and ordering helpers

gpuTileFraction reuses the multi-GPU attribution gate so the bar is present
exactly when the value is; memoryFraction guards a missing or zero total so
it never fabricates a proportion; tileOrder puts Battery in the grid only on
a machine that has one. Pure and directly tested, ahead of wiring the body."
```

---

### Task 4: Assemble the Overview — bar per tile, capped filling grid, conditional Battery

Wires the tested pieces into the page and the grid. The pure logic is covered by Tasks 1–3; this task is layout, verified by the existing Overview render test staying green and by a real screenshot at both window sizes (the project's rule: some things only screenshots catch).

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/Design/Tokens.swift` (add one token, near `chartMaxHeight` at line 74)
- Modify: `VitalsCore/Sources/VitalsUI/Components/TileLayout.swift:45-91` (TileGrid params)
- Modify: `VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift` (Tile model, tile builder, grid call, battery stream)
- Test: existing `VitalsCore/Tests/VitalsUITests/OverviewPageTests.swift` render test must stay green.

**Interfaces:**
- Consumes: `TileLayout.columnCount(...maximum:)` (Task 1); `MetricTile.init(...fraction:...)` (Task 2); `OverviewPage.gpuTileFraction`, `memoryFraction`, `tileOrder` (Task 3).
- Produces: no new public API beyond `TileGrid`'s two new parameters and `Vitals.Metrics.overviewTileMaxHeight`.

- [ ] **Step 1: Add the height-cap token**

In `VitalsCore/Sources/VitalsUI/Design/Tokens.swift`, immediately after the `chartMaxHeight` declaration (line 74), add:

```swift
        /// The tallest an Overview tile row grows to before the grid stops
        /// filling and leaves space below.
        ///
        /// The Overview grid divides height equally across its rows, so on an
        /// ordinary fullscreen window the tiles fill it — the state the layout
        /// was designed in. This ceiling engages only on an unusually tall
        /// window (a portrait display, a tall resize), where unbounded growth
        /// would recreate the very tallness this layout exists to cure, one row
        /// later. Set generously so the ordinary fullscreen look is unchanged;
        /// it is a backstop, not a visible constraint. Mirrors `chartMaxHeight`:
        /// a layout limit owned by the container, not the leaf.
        public static let overviewTileMaxHeight: CGFloat = 340
```

- [ ] **Step 2: Add the two parameters to `TileGrid`**

Replace `VitalsCore/Sources/VitalsUI/Components/TileLayout.swift:45-91` (the whole `TileGrid` struct) with:

```swift
/// A grid whose tiles reflow by width and grow into available height, up to an
/// optional per-row ceiling, with an optional cap on how many columns it forms.
public struct TileGrid<Item: Identifiable, Tile: View>: View {
    private let items: [Item]
    private let minimumTileWidth: CGFloat
    private let maximumColumns: Int
    private let maximumRowHeight: CGFloat
    private let spacing: CGFloat
    private let tile: (Item) -> Tile

    public init(
        items: [Item],
        minimumTileWidth: CGFloat = 240,
        maximumColumns: Int = .max,
        maximumRowHeight: CGFloat = .infinity,
        spacing: CGFloat = Vitals.Metrics.tileSpacing,
        @ViewBuilder tile: @escaping (Item) -> Tile
    ) {
        self.items = items
        self.minimumTileWidth = minimumTileWidth
        self.maximumColumns = maximumColumns
        self.maximumRowHeight = maximumRowHeight
        self.spacing = spacing
        self.tile = tile
    }

    public var body: some View {
        GeometryReader { proxy in
            let columns = TileLayout.columnCount(
                width: proxy.size.width,
                minimumTileWidth: minimumTileWidth,
                spacing: spacing,
                maximum: maximumColumns
            )
            let rows = TileLayout.rows(items, columns: columns)

            VStack(spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { item in
                            tile(item)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if TileLayout.shouldPadShortRows(rowCount: rows.count),
                           row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .frame(maxHeight: maximumRowHeight)
                }
                // When rows are capped, leftover height pools below rather than
                // stretching the tiles past the ceiling. When uncapped
                // (maximumRowHeight == .infinity) the rows consume everything
                // and this spacer collapses to zero — today's behaviour.
                Spacer(minLength: 0)
            }
        }
    }
}
```

- [ ] **Step 3: Give the Overview `Tile` model a fraction and build tiles from `tileOrder`**

In `VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift`, add `fraction` to the private `Tile` struct:

```swift
    private struct Tile: Identifiable {
        let id: String
        let label: String
        let value: String?
        let accent: Color
        let fraction: Double?
        let series: [ChartSeries]
    }
```

Replace the existing `private var tiles: [Tile]` computed property (the array literal building the five tiles) with a builder driven by `tileOrder`, so tile presence comes from the one tested place:

```swift
    private var tiles: [Tile] {
        Self.tileOrder(hasBattery: store.profile?.hasBattery == true).compactMap(tile(for:))
    }

    private func tile(for id: String) -> Tile? {
        switch id {
        case "cpu":
            return Tile(
                id: "cpu", label: "CPU",
                value: store.cpu.map { "\(Int(($0.total * 100).rounded()))%" },
                accent: Vitals.Palette.cpu,
                fraction: store.cpu?.total,
                series: cpuSeries
            )
        case "memory":
            return Tile(
                id: "memory", label: "Memory",
                value: store.memory.map { Vitals.formatKnownByteCountInGigabytes($0.used) },
                accent: Vitals.Palette.memory,
                fraction: Self.memoryFraction(
                    usedBytes: store.memory?.used,
                    totalBytes: store.profile?.memory.totalBytes
                ),
                series: memorySeries
            )
        case "gpu":
            return Tile(
                id: "gpu", label: "GPU",
                value: Self.gpuTileValue(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                accent: Vitals.Palette.gpu,
                fraction: Self.gpuTileFraction(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                series: gpuSeries
            )
        case "storage":
            return Tile(
                id: "storage", label: "Storage",
                value: StoragePage.primaryValue(store.diskIO),
                accent: Vitals.Palette.storage,
                fraction: nil,
                series: storageSeries
            )
        case "network":
            return Tile(
                id: "network", label: "Network",
                value: Self.networkTileValue(store.network),
                accent: Vitals.Palette.network,
                fraction: nil,
                series: networkSeries
            )
        case "battery":
            return Tile(
                id: "battery", label: "Battery",
                value: store.battery.map { "\($0.chargePercent)%" },
                accent: Vitals.Palette.battery,
                fraction: store.battery.map { Double($0.chargePercent) / 100 },
                series: batterySeries
            )
        default:
            return nil
        }
    }
```

(The `store.memory?.used` access assumes `MemorySample` exposes `used`; it is the same property `memorySeries` and the current Memory tile already read.)

- [ ] **Step 4: Add the Battery series builder**

Add near the other series builders in `OverviewPage.swift`:

```swift
    /// The Battery tile's spark: charge over time as a fraction, matching the
    /// tile's own percentage headline and its bar. Timestamps travel alongside
    /// so the chart breaks over the gaps that subscription-driven sampling
    /// leaves, exactly as every other tile series does.
    private var batterySeries: [ChartSeries] {
        [
            ChartSeries(
                name: "Charge",
                values: store.batteryHistory.map { Double($0.sample.chargePercent) / 100 },
                timestamps: store.batteryHistory.map(\.timestamp)
            )
        ]
    }
```

- [ ] **Step 5: Pass the fraction to `MetricTile`, cap the grid, and stream Battery conditionally**

In `OverviewPage.body`, update the `TileGrid` call and the `MetricTile` construction:

```swift
        TileGrid(
            items: tiles,
            // ~420pt gives two columns in a typical window and three at
            // fullscreen; the cap of three keeps an ultrawide display from
            // stranding a lopsided five-plus-one row. Together they guarantee
            // at least two rows, so no tile can fill the whole window height.
            minimumTileWidth: 420,
            maximumColumns: 3,
            maximumRowHeight: Vitals.Metrics.overviewTileMaxHeight
        ) { tile in
            MetricTile(
                label: tile.label,
                value: tile.value,
                accent: tile.accent,
                fraction: tile.fraction,
                series: tile.series
            )
        }
        .task { await store.stream(.cpu) }
        .task { await store.stream(.memory) }
        .task { await store.stream(.gpu) }
        .task { await store.stream(.diskIO) }
        .task { await store.stream(.network) }
        // Battery is sampled only where it exists — a desktop never subscribes
        // to a series it cannot show. The task runs on every machine but
        // returns immediately when there is no battery.
        .task {
            guard store.profile?.hasBattery == true else { return }
            await store.stream(.battery)
        }
```

- [ ] **Step 6: Update the Overview render test for the new grid geometry**

The `storageAndNetworkTilesSuppressTheAxisMaximumLabel` test renders a full
`OverviewPage` and asserts the axis-maximum label is absent at two hardcoded
`CGRect`s inside the Storage and Network tiles. That invariant still holds and
must stay tested — but the change here **moves those tiles**, so the two rects
must be re-derived. This is a legitimate layout change, not a regression.

Why it moves: the test renders at 900×700. Today the grid is `minimumTileWidth:
240`, so `columnCount(900, 240, 12) == 3` and the five tiles lay out as
`[CPU, Memory, GPU]` / `[Storage, Network, —]`. With the new `minimumTileWidth:
420, maximumColumns: 3`, `columnCount(900, 420, 12, maximum: 3) == 2`, which
reflows to three rows and puts Storage and Network in entirely different places.
(The store here has `profile: nil`, so `hasBattery` is false — this is the
five-tile desktop layout, and no proportion bars are drawn on Storage or Network
regardless, since both pass `fraction: nil`.)

- [ ] **Step 6a:** Change the render size in that test so the column *structure*
is preserved, which keeps the re-derivation to just the two rectangles. Render
at a width that still yields three columns under the new rule (`3 * 420 + 2 * 12
= 1284`, so use 1320). In `OverviewPageTests.swift`, change:

```swift
        let rendered = try renderPNG(
            OverviewPage(store: store),
            size: CGSize(width: 1320, height: 760),
            named: "overview-page-with-data"
        )
```

At 1320 wide the layout is again `[CPU, Memory, GPU]` / `[Storage, Network, —]`,
so Storage is still the first tile of the second row and Network the second —
the same structure the test was written for, only wider.

- [ ] **Step 6b:** Re-derive the two rects by the method the test's own doc
comment describes — there is no shortcut, because the tile widths changed. In
`MetricChart.init` the `showsAxisMaximum` flag is what the test exists to pin;
temporarily build with `MetricTile`'s `MetricChart(... showsAxisMaximum: true)`,
render this fixture, and find where the label lands on the Storage and Network
tiles (it is the only content that appears versus the `false` build). Take that
bounding box, pad it a few points on each side as the current rects do, and set:

```swift
        let storageLabelRegion = CGRect(x: <measured>, y: <measured>, width: <measured>, height: <measured>)
        let networkLabelRegion = CGRect(x: <measured>, y: <measured>, width: <measured>, height: <measured>)
```

Then restore `showsAxisMaximum: false`. Update the test's inline comment (the
long paragraph citing `x:[24.5, 60.0]` etc.) to the new measured values so it
stays truthful.

- [ ] **Step 6c:** Run `cd VitalsCore && swift test --filter OverviewPageTests`.
Expected: PASS, including the re-derived render test. If the probe still finds
content, the label is genuinely reaching the tile — that is a real bug in the
wiring (a stray `showsAxisMaximum: true`), not a coordinate problem; fix the
wiring, not the rect.

- [ ] **Step 7: Run the whole suite from a clean build**

Run: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning`
Expected: `0`.

Run: `cd VitalsCore && swift test`
Expected: PASS, with the suite count higher than before by the tests added in Tasks 1–3 (three + two + three = eight new tests).

- [ ] **Step 8: Visual check at both window sizes**

Run: `cd ~/Developer/Vitals && killall Vitals 2>/dev/null; ./scripts/build-app.sh && open build/Vitals.app`

Confirm on this machine (which has a battery, so six tiles):
- Windowed: two columns, three rows, no empty band, no clipping; every tile shows a sparkline; CPU/Memory/GPU/Battery show a proportion bar and Storage/Network do not.
- Fullscreen (green-button zoom, or resize wide): three columns, two rows, tiles fill the height without one tile ballooning.

Capture proof: read the window bounds via System Events, front the Vitals process, then `screencapture -x -R"$X,$Y,$W,$H" overview-after.png` (re-read the bounds immediately before capturing — a stale rect grabs the wrong window). Confirm the selected page is Overview via the accessibility API before trusting the shot.

- [ ] **Step 9: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/Design/Tokens.swift \
        VitalsCore/Sources/VitalsUI/Components/TileLayout.swift \
        VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift
git commit -m "feat: Overview tiles carry a proportion bar and fill the window

Six tiles on a laptop (Battery included), five on a desktop, in a grid capped
at three columns so they always form at least two rows — the single
full-height row that made the tiles balloon can no longer occur. Rows fill the
height up to overviewTileMaxHeight, a backstop for unusually tall windows that
mirrors chartMaxHeight. CPU, Memory, GPU and Battery carry a proportion bar;
throughput does not. Battery is sampled only where it exists.

Verified at both window sizes; full suite green from a clean build, 0 warnings."
```

---

## Notes for the implementer

- **Tile order is load-bearing** (AGENTS.md): the five base tiles stay CPU, Memory, GPU, Storage, Network. `tileOrder` pins this and Task 3 tests it — do not reorder.
- **`store.memory?.used`**: if `MemorySample`'s used-bytes property is named differently than `used`, use whatever the existing `memorySeries`/Memory tile already reads (they read the same value); the plan's `used` matches the current Memory tile at `OverviewPage.swift`'s `formatKnownByteCountInGigabytes($0.used)`.
- **No `SystemMetrics` struct gains a stored property here**, so the incremental-build SIGSEGV trap (AGENTS.md) does not apply — but Step 7's clean build is mandatory anyway for the warning check and because render tests need it.
- **Two greens on one screen** (Storage teal, Battery yellow-green): separated by Network in tile order and ~56° apart in hue. If they read as too close on the real screenshot in Step 8, raise it before committing — it is a palette question, not a layout bug, and out of this plan's scope to change unilaterally.
