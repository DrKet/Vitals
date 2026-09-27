# Menu-bar extra (first slice) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live CPU + memory readout in the macOS menu bar with a glance dropdown (five subsystem rows with sparklines, Open Vitals, Quit), and a lifecycle where Vitals keeps running in the menu bar after its window closes, with a Dock icon only while the window is open.

**Architecture:** SwiftUI `MenuBarExtra` (window style) beside a single-instance `Window` scene. The store, warm sampling and sidebar selection move from the window up to an app-level `AppModel`, shared by both scenes. The Overview's per-tile construction is lifted into `OverviewTiles` so the dropdown rows are provably the Overview's tiles. Pure pieces (`MenuBarReadout`, `AppLifecycle`, `OverviewTiles`) are unit-tested; the two views are render-tested; the app wiring is live-checked.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (`MenuBarExtra`, `Window`, `openWindow`), AppKit (`NSApplication.ActivationPolicy`), Swift Testing, the off-screen `NSWindow` render harness. macOS 26 floor.

**Spec:** `docs/superpowers/specs/2026-09-27-menu-bar-extra-design.md`

## Global Constraints

- **Never fabricate a number.** Unmeasured renders as an em dash via `MetricTile.displayValue` (`value ?? "—"`); never `0`, never a guess. Memory with no reported total (or a zero total) is an em dash.
- **One source per value.** The dropdown rows come from the same function the Overview uses; the menu-bar CPU and memory strings reuse the Overview's expressions. No second copy of any formatting.
- **Series order and time axes are load-bearing** (AGENTS.md): series keep their existing order and always carry `timestamps:`.
- **Render tests inside a panel use `regionHasSaturatedColor`, never `regionHasContent`.** Hue probes between the GPU (hue ≈ 0.069) and Network (≈ 0.110) accents need `tolerance: 0.015`; the default 0.05 cannot tell them apart.
- **Pixel probes read through `PixelGrid`; no blocking sleeps in main-actor tests** (AGENTS.md "Testing the UI").
- **Swift 6 language mode, strict concurrency, macOS 26.0 floor. No third-party dependencies.**
- **`swift test --filter` matches TYPE identifiers** (e.g. `MenuBarReadoutTests`), never `@Suite` names. A "0 tests" run is a failure to run.
- **Clean build before trusting results after struct/module changes:** `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`.
- **`swift run VitalsApp` shows nothing** — build the bundle: `./scripts/build-app.sh && open build/Vitals.app`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage files by name.

## File map

| File | Change | Responsibility |
|---|---|---|
| `Sources/VitalsUI/Pages/OverviewTiles.swift` | Create | `OverviewTile` + building any tile from the store |
| `Sources/VitalsUI/Pages/OverviewPage.swift` | Modify | uses `OverviewTiles`; its own tile code removed |
| `Sources/VitalsUI/MenuBar/MenuBarReadout.swift` | Create | pure CPU / memory menu-bar strings |
| `Sources/VitalsUI/Shell/AppLifecycle.swift` | Create | pure activation-policy rule |
| `Sources/VitalsUI/MenuBar/MenuBarLabel.swift` | Create | the menu-bar readout view |
| `Sources/VitalsUI/MenuBar/MenuBarPanel.swift` | Create | the dropdown view |
| `Sources/VitalsUI/Shell/AppShell.swift` | Modify | `init(store:selection:)`; `keepWarm` removed |
| `Sources/VitalsApp/VitalsApp.swift` | Modify | `AppModel`, `Window` + `MenuBarExtra` scenes, lifecycle |
| `Tests/VitalsUITests/OverviewTilesTests.swift` | Create | tile ids ↔ pages; unknown id |
| `Tests/VitalsUITests/MenuBarReadoutTests.swift` | Create | readout strings |
| `Tests/VitalsUITests/AppLifecycleTests.swift` | Create | activation policy |
| `Tests/VitalsUITests/MenuBarPanelTests.swift` | Create | label + panel renders |
| `AGENTS.md` | Modify | lifecycle note, current state |

Paths are relative to `VitalsCore/` unless they start with `AGENTS.md`, `docs/` or `scripts/`.

---

### Task 1: Spike — does macOS honour the label's styling? (controller, with owner)

Risk 1 in the spec, checked before anything depends on it. Throwaway: nothing is committed.

**Files:** temporary edit to `Sources/VitalsApp/VitalsApp.swift`, reverted at the end.

- [ ] **Step 1: Add a static `MenuBarExtra` to the app body**, after the `WindowGroup` scene:

```swift
        MenuBarExtra {
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text("23%").monospacedDigit()
                Image(systemName: "memorychip")
                Text("61%").monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
```

- [ ] **Step 2: Build and open:** `./scripts/build-app.sh && open build/Vitals.app`.
- [ ] **Step 3: Ask the owner to look at the menu bar** (no screenshots, no synthesized clicks — see memory `live-check-by-hand`): are both symbols and both values shown, in one item, with digits aligned? Then quit Vitals.
- [ ] **Step 4: Record the result in the ledger and revert:** `git checkout -- VitalsCore/Sources/VitalsApp/VitalsApp.swift`.

If the label is badly limited (only one symbol, text dropped), stop and escalate: the label moves to an `NSStatusItem` hosting `MenuBarLabel`, which changes Task 5.

---

### Task 2: `OverviewTiles` — one place that builds a tile

**Files:**
- Create: `Sources/VitalsUI/Pages/OverviewTiles.swift`
- Modify: `Sources/VitalsUI/Pages/OverviewPage.swift`
- Test: `Tests/VitalsUITests/OverviewTilesTests.swift`

**Interfaces:**
- Produces (module `VitalsUI`, internal unless noted):
  - `struct OverviewTile: Identifiable { let id: String; let label: String; let value: String?; let accent: Color; let fraction: Double?; let series: [ChartSeries] }`
  - `@MainActor enum OverviewTiles { static func tile(id: String, store: MetricsStore) -> OverviewTile?; static func tiles(ids: [String], store: MetricsStore) -> [OverviewTile]; static func percent(_ fraction: Double) -> String? }`
- `OverviewPage`'s existing statics (`tileOrder`, `memoryFraction`, `gpuTileValue`, `gpuTileFraction`, `gpuTileSeries`, `storageTileSeries`, `networkTileValue`, `networkTileSeries`) stay where they are — tests call them — and `OverviewTiles` calls them.

- [ ] **Step 1: Write the failing tests** — `Tests/VitalsUITests/OverviewTilesTests.swift`:

```swift
import Foundation
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Overview tiles")
struct OverviewTilesTests {

    private func emptyStore() -> MetricsStore {
        MetricsStore(engine: MetricsEngine(), profile: nil)
    }

    /// The dropdown opens a row's page through `SidebarSection(rawValue:)`,
    /// so every tile id the Overview can show must name a page.
    @Test("every Overview tile id names a sidebar page")
    func tileIDsNamePages() {
        for id in OverviewPage.tileOrder(hasBattery: true) {
            #expect(SidebarSection(rawValue: id) != nil, "tile \(id) has no page")
        }
    }

    @Test("tiles are built in the order asked for, and an unknown id builds nothing")
    func tilesFollowRequestedOrder() {
        let store = emptyStore()
        let ids = OverviewPage.tileOrder(hasBattery: false)
        #expect(OverviewTiles.tiles(ids: ids, store: store).map(\.id) == ids)
        #expect(OverviewTiles.tile(id: "nonsense", store: store) == nil)
    }

    /// An empty store has measured nothing: every tile's value is absent,
    /// never a zero.
    @Test("an empty store builds tiles with no values, not zeros")
    func emptyStoreHasNoValues() {
        let tiles = OverviewTiles.tiles(ids: OverviewPage.tileOrder(hasBattery: true), store: emptyStore())
        #expect(tiles.allSatisfy { $0.value == nil })
        #expect(tiles.allSatisfy { $0.fraction == nil })
    }

    @Test("percent rounds to a whole number and refuses a non-finite fraction")
    func percentFormatting() {
        #expect(OverviewTiles.percent(0.234) == "23%")
        #expect(OverviewTiles.percent(0.235) == "24%")
        #expect(OverviewTiles.percent(1.0) == "100%")
        #expect(OverviewTiles.percent(.nan) == nil)
        #expect(OverviewTiles.percent(.infinity) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter OverviewTilesTests`
Expected: build FAILS — `cannot find 'OverviewTiles' in scope`.

- [ ] **Step 3: Create `Sources/VitalsUI/Pages/OverviewTiles.swift`:**

```swift
import SwiftUI
import SystemMetrics

/// One Overview tile's worth of state: what it is called, what it reads, its
/// accent, its bar fraction and its sparkline.
struct OverviewTile: Identifiable {
    let id: String
    let label: String
    let value: String?
    let accent: Color
    let fraction: Double?
    let series: [ChartSeries]
}

/// Builds Overview tiles from the store — the one place a tile's value,
/// fraction and series are decided.
///
/// Shared by the Overview grid and the menu-bar dropdown, so a reading shown
/// in the menu bar is provably the one the Overview shows, including the
/// GPU page's multi-GPU attribution gate.
@MainActor
enum OverviewTiles {

    static func tiles(ids: [String], store: MetricsStore) -> [OverviewTile] {
        ids.compactMap { tile(id: $0, store: store) }
    }

    static func tile(id: String, store: MetricsStore) -> OverviewTile? {
        switch id {
        case "cpu":
            return OverviewTile(
                id: "cpu", label: "CPU",
                value: store.cpu.flatMap { percent($0.total) },
                accent: Vitals.Palette.cpu,
                fraction: store.cpu?.total,
                series: cpuSeries(store)
            )
        case "memory":
            return OverviewTile(
                id: "memory", label: "Memory",
                value: store.memory.map { Vitals.formatKnownByteCountInGigabytes($0.used) },
                accent: Vitals.Palette.memory,
                fraction: OverviewPage.memoryFraction(
                    usedBytes: store.memory?.used,
                    totalBytes: store.profile?.memory.totalBytes
                ),
                series: memorySeries(store)
            )
        case "gpu":
            return OverviewTile(
                id: "gpu", label: "GPU",
                value: OverviewPage.gpuTileValue(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                accent: Vitals.Palette.gpu,
                fraction: OverviewPage.gpuTileFraction(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                series: OverviewPage.gpuTileSeries(
                    history: store.gpuHistory,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                )
            )
        case "storage":
            return OverviewTile(
                id: "storage", label: "Storage",
                value: StoragePage.primaryValue(store.diskIO),
                accent: Vitals.Palette.storage,
                fraction: nil,
                series: OverviewPage.storageTileSeries(history: store.diskIOHistory)
            )
        case "network":
            return OverviewTile(
                id: "network", label: "Network",
                value: OverviewPage.networkTileValue(store.network),
                accent: Vitals.Palette.network,
                fraction: nil,
                series: OverviewPage.networkTileSeries(history: store.networkHistory)
            )
        case "battery":
            return OverviewTile(
                id: "battery", label: "Battery",
                value: store.battery.map { "\($0.chargePercent)%" },
                accent: Vitals.Palette.battery,
                fraction: store.battery.map { Double($0.chargePercent) / 100 },
                series: batterySeries(store)
            )
        default:
            return nil
        }
    }

    /// A fraction as a whole percentage — "23%". `nil` for a non-finite
    /// fraction: `Int(_:)` on NaN or infinity traps, and neither is a
    /// measurement.
    static func percent(_ fraction: Double) -> String? {
        guard let whole = Int(exactly: (fraction * 100).rounded()) else { return nil }
        return "\(whole)%"
    }

    private static func cpuSeries(_ store: MetricsStore) -> [ChartSeries] {
        [
            ChartSeries(
                name: "CPU",
                values: store.cpuHistory.map(\.sample.total),
                timestamps: store.cpuHistory.map(\.timestamp)
            )
        ]
    }

    private static func memorySeries(_ store: MetricsStore) -> [ChartSeries] {
        guard let total = store.profile?.memory.totalBytes, total > 0 else { return [] }
        return [
            ChartSeries(
                name: "Used",
                values: store.memoryHistory.map { Double($0.sample.used) / Double(total) },
                timestamps: store.memoryHistory.map(\.timestamp)
            )
        ]
    }

    /// The Battery tile's spark: charge over time as a fraction, matching the
    /// tile's own percentage headline and its bar.
    private static func batterySeries(_ store: MetricsStore) -> [ChartSeries] {
        [
            ChartSeries(
                name: "Charge",
                values: store.batteryHistory.map { Double($0.sample.chargePercent) / 100 },
                timestamps: store.batteryHistory.map(\.timestamp)
            )
        ]
    }
}
```

Note: the CPU value moves from `"\(Int(($0.total * 100).rounded()))%"` to `percent($0.total)` — identical for every finite value, and `nil` (em dash) instead of a trap for a non-finite one.

- [ ] **Step 4: Make `OverviewPage` use it.** In `Sources/VitalsUI/Pages/OverviewPage.swift`:
  - Delete the private `struct Tile`, the `tile(for:)` function, and the private computed properties `cpuSeries`, `memorySeries`, `gpuSeries`, `storageSeries`, `networkSeries`, `batterySeries` (with their doc comments). Keep every `static func` (`gpuTileValue`, `gpuTileFraction`, `gpuTileSeries`, `memoryFraction`, `storageTileSeries`, `networkTileValue`, `networkTileSeries`, `tileOrder`) exactly as they are.
  - Replace the `tiles` property with:

```swift
    private var tiles: [OverviewTile] {
        OverviewTiles.tiles(ids: Self.tileOrder(hasBattery: store.profile?.hasBattery == true), store: store)
    }
```

  - `body`'s `TileGrid(items: tiles, …) { tile in MetricTile(label: tile.label, value: tile.value, accent: tile.accent, fraction: tile.fraction, series: tile.series) }` compiles unchanged against `OverviewTile`.

- [ ] **Step 5: Run the new tests and the Overview's existing tests**

Run: `swift test --filter OverviewTilesTests` — expected 4 tests PASS.
Run: `swift test --filter OverviewPageTests` — expected PASS, **with no test edited**: they are the regression proof that the refactor changed no tile.

- [ ] **Step 6: Full suite, commit**

Run `swift test` — all pass.

```bash
git add VitalsCore/Sources/VitalsUI/Pages/OverviewTiles.swift VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift VitalsCore/Tests/VitalsUITests/OverviewTilesTests.swift
git commit -m "refactor: OverviewTiles builds every Overview tile in one place

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `MenuBarReadout` and `AppLifecycle` — the pure rules

**Files:**
- Create: `Sources/VitalsUI/MenuBar/MenuBarReadout.swift`
- Create: `Sources/VitalsUI/Shell/AppLifecycle.swift`
- Test: `Tests/VitalsUITests/MenuBarReadoutTests.swift`, `Tests/VitalsUITests/AppLifecycleTests.swift`

**Interfaces:**
- Consumes: `OverviewTiles.percent(_:)` (Task 2), `OverviewPage.memoryFraction(usedBytes:totalBytes:)`, `MetricTile.displayValue(_:)`.
- Produces (public):
  - `@MainActor enum MenuBarReadout { static func cpu(_ sample: CPULoadSample?) -> String; static func memory(_ sample: MemorySample?, totalBytes: UInt64?) -> String }` — always a display string; an em dash when unmeasured. `@MainActor` because it calls `OverviewPage.memoryFraction` and `OverviewTiles.percent`, which are main-actor isolated (`OverviewPage` is a SwiftUI `View`).
  - `enum AppLifecycle { static func activationPolicy(mainWindowOpen: Bool) -> NSApplication.ActivationPolicy }`

- [ ] **Step 1: Write the failing tests**

`Tests/VitalsUITests/MenuBarReadoutTests.swift`:

```swift
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Menu-bar readout")
struct MenuBarReadoutTests {

    private static func cpu(_ busy: Double) -> CPULoadSample {
        CPULoadSample(cores: [CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0)])
    }

    private static func memory(usedGiB: UInt64) -> MemorySample {
        let gib: UInt64 = 1 << 30
        return MemorySample(
            app: usedGiB * gib, wired: 0, compressed: 0, cached: 0,
            free: 0, swapUsed: nil, swapTotal: nil, pressure: nil
        )
    }

    @Test("CPU reads as the Overview tile's whole percentage")
    func cpuPercentage() {
        #expect(MenuBarReadout.cpu(Self.cpu(0.234)) == "23%")
        #expect(MenuBarReadout.cpu(Self.cpu(1.0)) == "100%")
    }

    @Test("memory reads as used over total, as a whole percentage")
    func memoryPercentage() {
        let total: UInt64 = 16 << 30
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: total) == "25%")
    }

    /// Never a zero or a guess: nothing measured, or no whole to be a
    /// fraction of, reads as the same em dash a tile shows.
    @Test("unmeasured, or memory without a total, is an em dash")
    func absenceIsAnEmDash() {
        #expect(MenuBarReadout.cpu(nil) == "—")
        #expect(MenuBarReadout.memory(nil, totalBytes: 16 << 30) == "—")
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: nil) == "—")
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: 0) == "—")
    }
}
```

`Tests/VitalsUITests/AppLifecycleTests.swift`:

```swift
import AppKit
import Testing
@testable import VitalsUI

@Suite("App lifecycle")
struct AppLifecycleTests {

    /// A Dock icon only while the main window is open; the menu-bar item
    /// carries the app otherwise.
    @Test("the Dock icon follows the main window")
    func activationPolicyFollowsTheWindow() {
        #expect(AppLifecycle.activationPolicy(mainWindowOpen: true) == .regular)
        #expect(AppLifecycle.activationPolicy(mainWindowOpen: false) == .accessory)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MenuBarReadoutTests` and `swift test --filter AppLifecycleTests`
Expected: build FAILS — `cannot find 'MenuBarReadout' / 'AppLifecycle' in scope`.

- [ ] **Step 3: Implement**

`Sources/VitalsUI/MenuBar/MenuBarReadout.swift`:

```swift
import SystemMetrics

/// The menu-bar readout's two strings. Built from the Overview's own pieces —
/// its percentage formatting and its memory fraction — so the menu bar cannot
/// disagree with the tiles, and worded for absence exactly as a tile is.
///
/// Main-actor isolated because those pieces are: `OverviewPage` is a SwiftUI
/// `View`, and `OverviewTiles` builds tiles from the main-actor store.
@MainActor
public enum MenuBarReadout {

    public static func cpu(_ sample: CPULoadSample?) -> String {
        MetricTile.displayValue(sample.flatMap { OverviewTiles.percent($0.total) })
    }

    /// Used over total, as a percentage — the Memory tile's bar fraction, where
    /// the tile's headline is gigabytes. No total, or a zero one, is no whole
    /// to be a fraction of: an em dash, never a guess.
    public static func memory(_ sample: MemorySample?, totalBytes: UInt64?) -> String {
        let fraction = OverviewPage.memoryFraction(usedBytes: sample?.used, totalBytes: totalBytes)
        return MetricTile.displayValue(fraction.flatMap(OverviewTiles.percent))
    }
}
```

`Sources/VitalsUI/Shell/AppLifecycle.swift`:

```swift
import AppKit

/// How Vitals presents itself as an app.
public enum AppLifecycle {

    /// A Dock icon and Cmd-Tab entry only while the main window is open. With
    /// it closed, Vitals keeps running as an accessory: the menu-bar item is
    /// its only presence, which is the point of having one.
    public static func activationPolicy(mainWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        mainWindowOpen ? .regular : .accessory
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter MenuBarReadoutTests` — 3 tests PASS. `swift test --filter AppLifecycleTests` — 1 PASS.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/MenuBar/MenuBarReadout.swift VitalsCore/Sources/VitalsUI/Shell/AppLifecycle.swift VitalsCore/Tests/VitalsUITests/MenuBarReadoutTests.swift VitalsCore/Tests/VitalsUITests/AppLifecycleTests.swift
git commit -m "feat: menu-bar readout strings and the Dock-icon rule

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `MenuBarLabel` and `MenuBarPanel` — the two views

**Files:**
- Create: `Sources/VitalsUI/MenuBar/MenuBarLabel.swift`
- Create: `Sources/VitalsUI/MenuBar/MenuBarPanel.swift`
- Test: `Tests/VitalsUITests/MenuBarPanelTests.swift`

**Interfaces:**
- Consumes: `MenuBarReadout` (Task 3), `OverviewTiles` / `OverviewTile` (Task 2), `OverviewPage.tileOrder(hasBattery:)`, `SidebarSection(rawValue:)`, `MetricChart(series:style:colors:showsAxisMaximum:)`, render harness (`renderPNG`, `regionHasSaturatedColor(in:region:matchingHueOf:tolerance:)`, `regionHasSaturatedColor(in:region:)`, `hue(of:)`).
- Produces (public):
  - `struct MenuBarLabel: View { init(store: MetricsStore?) }`
  - `struct MenuBarPanel: View { init(store: MetricsStore, onOpenPage: @escaping (SidebarSection) -> Void, onOpenVitals: @escaping () -> Void, onQuit: @escaping () -> Void) }` and `static let width: CGFloat = 320`
  - `MenuBarPanel.rowIDs: [String]` (static, internal) = `OverviewPage.tileOrder(hasBattery: false)`

- [ ] **Step 1: Write the failing tests** — `Tests/VitalsUITests/MenuBarPanelTests.swift`:

```swift
import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Menu-bar panel")
struct MenuBarPanelTests {

    private static let panelSize = CGSize(width: MenuBarPanel.width, height: 420)

    /// A store holding a few ticks of every kept-warm series, so each row has
    /// a value and a sparkline. The real hardware profile, so memory has a
    /// total and the GPU attribution gate sees this machine's GPU count.
    private func liveStore() async throws -> MetricsStore {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        var busy = 0.2
        await engine.register(AnySampler {
            busy = busy >= 0.9 ? 0.2 : busy + 0.1
            return CPULoadSample(cores: [CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0)])
        }, for: .cpu, cadence: .fast)
        let profile = try HardwareProfile.detect()
        let total = profile.memory.totalBytes
        await engine.register(AnySampler {
            MemorySample(app: total * 4 / 10, wired: total * 3 / 10, compressed: 0, cached: 0,
                         free: total * 3 / 10, swapUsed: nil, swapTotal: nil, pressure: nil)
        }, for: .memory, cadence: .fast)
        let gpuCount = profile.gpus.count
        await engine.register(AnySampler {
            Array(repeating: GPUSample(deviceUtilisation: 0.8, rendererUtilisation: 0.6, tilerUtilisation: 0.2,
                                       inUseMemoryBytes: 1_000, allocatedMemoryBytes: 2_000), count: gpuCount)
        }, for: .gpu, cadence: .fast)
        await engine.register(AnySampler {
            ["disk0": DiskThroughput(bytesReadPerSecond: 4_194_304, bytesWrittenPerSecond: 524_288)]
        }, for: .diskIO, cadence: .fast)
        await engine.register(AnySampler {
            ["en0": NetworkThroughput(bytesInPerSecond: 4_194_304, bytesOutPerSecond: 524_288)]
        }, for: .network, cadence: .fast)

        let store = MetricsStore(engine: engine, profile: profile)
        let tasks = [SeriesKey.cpu, .memory, .gpu, .diskIO, .network].map { key in
            Task { await store.stream(key) }
        }
        try await waitUntil {
            store.cpuHistory.count >= 3 && store.memoryHistory.count >= 3 && store.gpuHistory.count >= 3
                && store.diskIOHistory.count >= 3 && store.networkHistory.count >= 3
        }
        tasks.forEach { $0.cancel() }
        return store
    }

    private func panel(_ store: MetricsStore) -> MenuBarPanel {
        MenuBarPanel(store: store, onOpenPage: { _ in }, onOpenVitals: {}, onQuit: {})
    }

    @Test("the dropdown shows the five kept-warm subsystems, in Overview order, each opening its own page")
    func rowsAreTheKeptWarmTilesInOrder() {
        #expect(MenuBarPanel.rowIDs == ["cpu", "memory", "gpu", "storage", "network"])
        for id in MenuBarPanel.rowIDs {
            #expect(SidebarSection(rawValue: id) != nil)
        }
    }

    /// Each row's sparkline paints in its own subsystem's accent. The GPU and
    /// Network accents are ~0.04 apart in hue, so the tolerance is tight —
    /// the default 0.05 would let one pass for the other.
    @Test("with live data, every row's sparkline paints its own accent")
    func everyRowPaintsItsAccent() async throws {
        let store = try await liveStore()
        let rendered = try renderPNG(panel(store), size: Self.panelSize, named: "menubar-panel-live")
        let whole = CGRect(origin: .zero, size: Self.panelSize)
        for accent in [Vitals.Palette.cpu, Vitals.Palette.memory, Vitals.Palette.gpu,
                       Vitals.Palette.storage, Vitals.Palette.network] {
            #expect(
                try regionHasSaturatedColor(in: rendered, region: whole, matchingHueOf: [hue(of: accent)], tolerance: 0.015),
                "no pixel in hue \(hue(of: accent))"
            )
        }
    }

    /// Nothing measured must paint nothing: no zero-height bars or flat
    /// sparklines in an accent, which would read as a measured zero.
    @Test("with an empty store, the dropdown paints no accent colour anywhere")
    func emptyStorePaintsNoAccent() throws {
        let empty = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(panel(empty), size: Self.panelSize, named: "menubar-panel-empty")
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(origin: .zero, size: Self.panelSize)))
    }

    @Test("the menu-bar label renders with and without a store")
    func labelRenders() async throws {
        _ = try renderPNG(MenuBarLabel(store: nil), size: CGSize(width: 160, height: 22), named: "menubar-label-empty")
        let store = try await liveStore()
        _ = try renderPNG(MenuBarLabel(store: store), size: CGSize(width: 160, height: 22), named: "menubar-label-live")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MenuBarPanelTests`
Expected: build FAILS — `cannot find 'MenuBarPanel' / 'MenuBarLabel' in scope`.

- [ ] **Step 3: Implement `Sources/VitalsUI/MenuBar/MenuBarLabel.swift`:**

```swift
import SwiftUI

/// The menu-bar readout: CPU and memory, each a symbol and a value, digits
/// monospaced so the item's width does not jitter as values change. No store
/// yet (still starting, or startup failed) reads as em dashes, like any
/// unmeasured value.
public struct MenuBarLabel: View {
    private let store: MetricsStore?

    public init(store: MetricsStore?) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
            Text(MenuBarReadout.cpu(store?.cpu)).monospacedDigit()
            Image(systemName: "memorychip")
            Text(MenuBarReadout.memory(store?.memory, totalBytes: store?.profile?.memory.totalBytes))
                .monospacedDigit()
        }
    }
}
```

- [ ] **Step 4: Implement `Sources/VitalsUI/MenuBar/MenuBarPanel.swift`:**

```swift
import SwiftUI

/// The menu-bar dropdown: one row per kept-warm subsystem — built by the
/// Overview's own `OverviewTiles`, so each value is the tile's — and a footer.
///
/// Actions are closures so the panel renders in tests without an app; the app
/// supplies window-opening and quitting.
public struct MenuBarPanel: View {
    public static let width: CGFloat = 320

    /// The kept-warm series, in Overview order. Battery and Sensors are left
    /// out: they are not kept warm, so a row for them would be empty until a
    /// subscription of its own filled it.
    static let rowIDs = OverviewPage.tileOrder(hasBattery: false)

    private let store: MetricsStore
    private let onOpenPage: (SidebarSection) -> Void
    private let onOpenVitals: () -> Void
    private let onQuit: () -> Void

    public init(
        store: MetricsStore,
        onOpenPage: @escaping (SidebarSection) -> Void,
        onOpenVitals: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenPage = onOpenPage
        self.onOpenVitals = onOpenVitals
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(OverviewTiles.tiles(ids: Self.rowIDs, store: store)) { tile in
                Button {
                    if let section = SidebarSection(rawValue: tile.id) { onOpenPage(section) }
                } label: {
                    row(tile)
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Open Vitals", action: onOpenVitals)
                Spacer()
                Button("Quit Vitals", action: onQuit)
            }
        }
        .padding(12)
        .frame(width: Self.width)
    }

    private func row(_ tile: OverviewTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tile.label).font(Vitals.Typography.label)
                Spacer()
                Text(MetricTile.displayValue(tile.value))
                    .font(Vitals.Typography.label)
                    .monospacedDigit()
            }
            if !tile.series.isEmpty {
                MetricChart(
                    series: tile.series,
                    style: .area(stacked: tile.series.count > 1),
                    colors: [tile.accent],
                    showsAxisMaximum: false
                )
                .frame(height: 28)
            }
        }
        .contentShape(Rectangle())
    }
}
```

If `MetricChart` paints any accent for a series with values but the empty-store test fails because an *empty* `series` array still reaches it, the `if !tile.series.isEmpty` guard is what prevents that — keep it. If `emptyStorePaintsNoAccent` fails for any other reason, report it (NEEDS_CONTEXT) rather than weakening the test: it would mean something paints a colour for data that was never measured.

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter MenuBarPanelTests` — 4 tests PASS. Open `/tmp/vitals-render/menubar-panel-live.png` and `menubar-label-live.png` and look at them; note in your report what they show.

- [ ] **Step 6: Prove the hue test can fail**

Temporarily change `colors: [tile.accent]` to `colors: [Vitals.Palette.cpu]`. Run `swift test --filter MenuBarPanelTests`: `everyRowPaintsItsAccent` must FAIL for the memory, GPU, storage and network hues. Restore; rerun; PASS.

- [ ] **Step 7: Clean build, full suite, commit**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected `0`. Run `swift test` — all pass.

```bash
git add VitalsCore/Sources/VitalsUI/MenuBar/MenuBarLabel.swift VitalsCore/Sources/VitalsUI/MenuBar/MenuBarPanel.swift VitalsCore/Tests/VitalsUITests/MenuBarPanelTests.swift
git commit -m "feat: menu-bar label and dropdown panel views

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: App wiring — `AppModel`, the two scenes, the lifecycle

**Files:**
- Modify: `Sources/VitalsApp/VitalsApp.swift`
- Modify: `Sources/VitalsUI/Shell/AppShell.swift`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: `MenuBarLabel`, `MenuBarPanel` (Task 4), `AppLifecycle.activationPolicy(mainWindowOpen:)` (Task 3).
- Produces: `AppShell.init(store:selection:)` (public), taking `Binding<SidebarSection>`.

No new unit tests: this is scene and AppKit glue, verified by building the bundle, `scripts/verify-app.sh`, and the owner's live check (Task 6). Every decision in it is already tested in Tasks 2–4.

- [ ] **Step 1: `AppShell` takes its selection from outside, and stops starting `keepWarm`.** In `Sources/VitalsUI/Shell/AppShell.swift`, replace the stored selection and `init`:

```swift
public struct AppShell: View {
    @State private var localSelection: SidebarSection = .overview
    private let externalSelection: Binding<SidebarSection>?
    private let store: MetricsStore

    /// Owns its own selection — for callers with nothing else to drive it.
    public init(store: MetricsStore) {
        self.store = store
        self.externalSelection = nil
    }

    /// Selection owned by the caller, so something outside the window (the
    /// menu-bar dropdown) can choose which page it shows.
    public init(store: MetricsStore, selection: Binding<SidebarSection>) {
        self.store = store
        self.externalSelection = selection
    }

    private var selection: Binding<SidebarSection> {
        externalSelection ?? $localSelection
    }
```

  Then change `List(selection: $selection)` to `List(selection: selection)` and `switch selection {` in `detail` to `switch selection.wrappedValue {`. Delete the `.task { await store.keepWarm() }` modifier and its comment block — `AppModel` now owns warm sampling for the whole app lifetime (Step 2).

- [ ] **Step 2: Rewrite `Sources/VitalsApp/VitalsApp.swift`:**

```swift
import AppKit
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

/// Keeps Vitals running when its window closes: the menu-bar item carries it
/// from then on, and the Dock icon goes with the window (`AppLifecycle`).
/// Quit is explicit — the dropdown's Quit Vitals, or ⌘Q.
///
/// A windowless Vitals is intended now, and always visible in the menu bar.
/// The trap to still watch for is different: running the raw executable
/// outside a bundle — `swift run VitalsApp`, or the binary under `.build/` —
/// launches background-only with zero windows *and no menu-bar item*. Use
/// `scripts/build-app.sh && open build/Vitals.app`; `scripts/verify-app.sh`
/// is what proves a window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// State both scenes share, created once for the app's lifetime: the store
/// (and so every series' history), warm sampling, and which page the window
/// shows. Held here rather than in the window so closing and reopening the
/// window never rebuilds it.
@MainActor
@Observable
final class AppModel {
    private(set) var store: MetricsStore?
    private(set) var startupError: String?
    var selection: SidebarSection = .overview
    private var warmSampling: Task<Void, Never>?

    init() {
        Task { await start() }
    }

    private func start() async {
        do {
            let profile = try HardwareProfile.detect()
            let engine = MetricsEngine()
            await StandardSamplers.registerAll(on: engine)
            let store = MetricsStore(engine: engine, profile: profile)
            self.store = store
            // The menu-bar readout and dropdown show exactly the kept-warm
            // series, so they sample for as long as the app runs — with or
            // without a window. See `MetricsStore.keepWarm()`.
            warmSampling = Task { await store.keepWarm() }
        } catch {
            // Surfaced rather than swallowed: if the machine cannot describe its
            // own hardware, saying so beats an empty window.
            startupError = "Could not read this machine's hardware: \(error)"
        }
    }
}

enum MainWindow {
    static let id = "main"
}

@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // `Window`, not `WindowGroup`: one main window. `openWindow(id:)` then
        // brings that window back instead of opening a second one.
        Window("Vitals", id: MainWindow.id) {
            MainWindowContent(model: model)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MainWindowContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let store = model.store {
                AppShell(store: store, selection: $model.selection)
            } else if let startupError = model.startupError {
                Text(startupError)
                    .padding()
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { NSApp.setActivationPolicy(AppLifecycle.activationPolicy(mainWindowOpen: true)) }
        .onDisappear { NSApp.setActivationPolicy(AppLifecycle.activationPolicy(mainWindowOpen: false)) }
    }
}

private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let store = model.store {
            MenuBarPanel(
                store: store,
                onOpenPage: { section in
                    model.selection = section
                    showMainWindow()
                },
                onOpenVitals: showMainWindow,
                onQuit: { NSApp.terminate(nil) }
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.startupError ?? "Starting…")
                Button("Quit Vitals") { NSApp.terminate(nil) }
            }
            .padding(12)
            .frame(width: MenuBarPanel.width)
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(AppLifecycle.activationPolicy(mainWindowOpen: true))
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}
```

- [ ] **Step 3: Build clean, run the suite**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected `0`. Run `swift test` — all pass.

- [ ] **Step 4: Build the bundle and run the verifier**

```bash
./scripts/build-app.sh
```
Expected: ends `==> All checks passed` — the main window still opens at launch, and the verifier's explicit quit still quits.

- [ ] **Step 5: Update `AGENTS.md`**
  - In "Platform notes worth knowing", the bullet beginning "A SwiftPM executable has no bundle": after its last sentence add: "Closing the window no longer quits a bundled Vitals — it keeps running in the menu bar (see `AppDelegate`). A windowless *bundled* Vitals is expected; one with no menu-bar item either is the unbundled trap above."
  - In "Current state", add to the "Complete:" list: "a menu-bar extra (CPU + memory readout, a five-row glance dropdown that opens pages; Vitals stays running in the menu bar when its window closes)".
  - In "Not built yet", change "desktop widgets and the menu-bar extra" to "desktop widgets; the menu-bar extra's later slices (configurable readouts, top processes, throttling while closed)".

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsApp/VitalsApp.swift VitalsCore/Sources/VitalsUI/Shell/AppShell.swift AGENTS.md
git commit -m "feat: menu-bar extra wired into the app; Vitals stays running without its window

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Live check (controller, with owner)

Needs the owner at the machine; no screenshots or synthesized clicks.

- [ ] **Step 1:** `./scripts/build-app.sh && open build/Vitals.app`.
- [ ] **Step 2: Hand the owner this checklist** and record results in the ledger:
  1. The menu bar shows the CPU symbol and a %, the memory-chip symbol and a %; values change every second or two; width doesn't jitter.
  2. Click the item: five rows (CPU, Memory, GPU, Storage, Network), each with a value and a moving sparkline in its colour; values match the Overview page's tiles (memory as % here, GB on the tile).
  3. Close the main window (red button): Vitals keeps running — readout still live — and its Dock icon disappears.
  4. Dropdown → **Open Vitals**: the window returns, Dock icon back, Cmd-Tab lists Vitals; the charts still have their history (the store was not rebuilt).
  5. Close the window again; dropdown → click the **GPU** row: the window opens on the GPU page.
  6. Dropdown → **Quit Vitals**: the app exits and the menu-bar item disappears.
- [ ] **Step 3:** Any failure is a defect to fix and re-review before merge.
