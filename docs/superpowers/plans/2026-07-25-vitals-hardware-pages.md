# Vitals Hardware Pages Implementation Plan (M1-B-2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Memory, GPU, Storage, and Network hardware pages on a shared container extracted from the CPU page, and wire the disk I/O data source the spec requires but M1-A left unconnected.

**Architecture:** The CPU page carries roughly 250 lines of scaffold — header with vendor mark, glass panels, scroll container, four-stat block, sticky disclosure — that four more pages would duplicate. Task 1 extracts that into a `HardwarePage` container and refactors `CPUPage` onto it, so each page contributes only its data mapping. That is what makes the five pages actually identical in behaviour rather than merely similar-looking, and it is why the container comes before any new page.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, `ImageRenderer` for headless render verification.

## Global Constraints

- **Platform floor:** macOS 26.0. Swift language mode 6, strict concurrency.
- **No third-party dependencies.** Foundation, SwiftUI, Observation, Darwin, IOKit, Metal, Swift Testing only.
- **Never fabricate a number.** An unmeasurable value is `nil` and renders as "Unavailable" (`StatRow.displayValue`) or an em dash (`MetricTile.displayValue`) — never `0`, never blank. A series with no reading is **omitted from the chart**, never zero-filled: a flat 0% band is a measurement the machine never reported.
- **Subscription-driven.** A page subscribes only to the series it displays, via `.task { await store.stream(_:) }`, and releases them when it disappears.
- **Build and test output must be pristine** — no warnings.
- **Package root:** `VitalsCore/`. Paths are relative to `/Users/george/Developer/Vitals`.
- **Test command:** `cd VitalsCore && swift test`.
- **`swift test --filter` matches type identifiers, not `@Suite` display names.** `--filter MemoryPageTests` works; `--filter "Memory page"` matches zero tests and still reports success. A run reporting "Test run with 0 tests ... passed" is a failure to run.
- **Charts carry a time axis.** Every `ChartSeries` built from store history must pass `timestamps:` alongside `values:`, or gap-breaking silently stops working for that page.

## Consumed API (verified against the built package)

```swift
// Store — history elements are timestamped
public struct Timestamped<Sample: Sendable>: Sendable {
    public let timestamp: TimeInterval
    public let sample: Sample
}
@Observable @MainActor public final class MetricsStore {
    public private(set) var cpu: CPULoadSample?
    public private(set) var cpuHistory: [Timestamped<CPULoadSample>]
    public private(set) var memory: MemorySample?
    public private(set) var memoryHistory: [Timestamped<MemorySample>]
    public var systemLoad: SystemLoad { get }
    public let profile: HardwareProfile?
    public func stream(_ key: SeriesKey) async
}

// Chart
public struct ChartSeries {
    public init(name: String, values: [Double], timestamps: [TimeInterval] = [], unit: ChartUnit = .fraction)
}
public enum ChartUnit { case fraction; case absolute(suffix: String) }
public struct MetricChart { public init(series: [ChartSeries], style: ChartStyle, colors: [Color]) }
public enum ChartStyle { case area(stacked: Bool); case histogram }

// Components
public struct StatRow { public init(label: String, value: String?)
                        public static func displayValue(_ value: String?) -> String }  // nil -> "Unavailable"
public struct GlassPanel<Content: View> { public init(cornerRadius:CGFloat, @ViewBuilder content: () -> Content) }
public enum Vitals { enum Palette; enum Metrics; enum Typography
                     static func seriesColors(count: Int) -> [Color] }

// Payload types per series
// .memory  -> MemorySample(app/wired/compressed/cached/free: UInt64, used: UInt64,
//                          swapUsed/swapTotal: UInt64?, pressure: MemoryPressure?)
// .gpu     -> [GPUSample](deviceUtilisation/rendererUtilisation/tilerUtilisation: Double?,
//                          inUseMemoryBytes/allocatedMemoryBytes: UInt64?)
// .storage -> [Volume](name, totalBytes, availableBytes, isInternal, usedBytes, usedFraction)
// .network -> [String: NetworkThroughput](bytesInPerSecond, bytesOutPerSecond)

public struct MemoryHardware { public let totalBytes: UInt64; public let type: String?
                               public let manufacturer: String?; public let isUnified: Bool
                               public let slots: [MemorySlot]; public let peakBandwidthGBs: Double?
                               public var speedMHz: Int? }
public struct GPUDevice { public let name: String; public let topology: GPUMemoryTopology
                          public let coreCount: Int? }
public enum GPUMemoryTopology { case unified(systemBytes: UInt64)
                                case dedicated(vramBytes: UInt64)
                                case shared(maxSharedBytes: UInt64) }
public enum StorageSampler { public static func ioCounters() -> [String: StorageIOCounters] }
public struct StorageIOCounters { public let bytesRead: UInt64; public let bytesWritten: UInt64 }
public struct DeltaCounter<Value: FixedWidthInteger & Sendable> {
    public mutating func update(_ value: Value, at timestamp: TimeInterval) -> Delta<Value>?
}
```

## The stacked decompositions this plan implements

From spec §6.3. Each is the reason its page uses `.area(stacked: true)`:

| Page | Series, base first | Unit |
|---|---|---|
| Memory | Wired / App / Compressed / Cached | `.fraction` of installed |
| GPU | Renderer / Tiler | `.fraction` |
| Storage | Read / Write | `.absolute(suffix: "MB/s")` |
| Network | Down / Up | `.absolute(suffix: "MB/s")` |

Series order is load-bearing: the first series is the base band, is painted frontmost, and is the one the live dot marks.

## Out of scope for this plan

- **The Sensors page.** `UnavailableSensorProvider.readings()` returns `[]` by design — temperatures, fans, and power all need `IOHIDEventSystemClient`, a private framework whose implementation needs an empirical spike rather than plan-written code. A page today could only restate what the sidebar's existing "Not built yet" placeholder already says, and would be rewritten wholesale once real data exists. The sidebar entry stays as it is.
- **The Processes pane.** That is M1-B-3.
- **Per-process GPU, power, and SMART health.** Those need the privileged helper — milestone M3.

---

### Task 1: Extract the shared hardware page container

Four more pages would each duplicate the CPU page's scaffold. Extracting it first is what keeps them genuinely identical instead of drifting apart, and it is why this task precedes every page.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/HardwarePage.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Pages/CPUPage.swift`
- Test: `VitalsCore/Tests/VitalsUITests/HardwarePageTests.swift`

**Interfaces:**
- Consumes: `GlassPanel`, `MetricChart`, `StatRow`, `ChartSeries`, `Vitals` tokens.
- Produces: `HardwareStat` (`label: String`, `value: String?`, `id: String`); `HardwarePage<Secondary: View, Specs: View>` with `init(title:vendorName:showsAppleMark:primaryValue:series:stats:disclosureKey:secondary:specifications:)`. Tasks 4–7 all build on it.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/HardwarePageTests.swift`:

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Hardware page")
struct HardwarePageTests {

    private func page(primaryValue: String?, stats: [HardwareStat]) -> some View {
        HardwarePage(
            title: "Memory",
            vendorName: "16 GB LPDDR5",
            showsAppleMark: true,
            primaryValue: primaryValue,
            series: [
                ChartSeries(name: "Wired", values: [0.2, 0.3, 0.25]),
                ChartSeries(name: "App", values: [0.3, 0.3, 0.35]),
            ],
            stats: stats,
            disclosureKey: "test.memory"
        ) {
            Text("secondary")
        } specifications: {
            StatRow(label: "Type", value: "LPDDR5")
        }
    }

    @Test("renders a full page with a value, chart, stats and disclosure")
    func rendersFullPage() throws {
        let view = page(
            primaryValue: "13.9 GB",
            stats: [
                HardwareStat(label: "Installed", value: "16 GB"),
                HardwareStat(label: "Swap", value: "2.1 GB"),
            ]
        )
        let url = try renderPNG(view, size: CGSize(width: 800, height: 600), named: "hardware-page")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an absent primary value renders an em dash, never a zero")
    func absentPrimaryValueIsEmDash() {
        #expect(HardwarePage<EmptyView, EmptyView>.displayPrimary(nil) == "—")
        #expect(HardwarePage<EmptyView, EmptyView>.displayPrimary("42%") == "42%")
    }

    @Test("a stat with no reading renders Unavailable, matching StatRow's house rule")
    func absentStatIsUnavailable() {
        // The container must not invent its own wording for absence.
        #expect(StatRow.displayValue(HardwareStat(label: "Speed", value: nil).value) == "Unavailable")
    }

    @Test("stats are identified by label so SwiftUI can diff them")
    func statsAreIdentifiable() {
        let stat = HardwareStat(label: "Installed", value: "16 GB")
        #expect(stat.id == "Installed")
    }

    @Test("a page with no series still renders")
    func emptySeriesRenders() throws {
        let view = HardwarePage(
            title: "GPU",
            vendorName: nil,
            showsAppleMark: false,
            primaryValue: nil,
            series: [],
            stats: [],
            disclosureKey: "test.empty"
        ) {
            EmptyView()
        } specifications: {
            EmptyView()
        }
        let url = try renderPNG(view, size: CGSize(width: 600, height: 400), named: "hardware-page-empty")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter HardwarePageTests`
Expected: FAIL — `cannot find 'HardwarePage' in scope`.

- [ ] **Step 3: Write the container**

Create `VitalsCore/Sources/VitalsUI/Pages/HardwarePage.swift`:

```swift
import SwiftUI

/// One labelled statistic in a hardware page's key-stats block.
public struct HardwareStat: Identifiable, Sendable, Equatable {
    public let label: String
    /// `nil` renders as "Unavailable" via `StatRow` — never as `0` or blank.
    public let value: String?

    public var id: String { label }

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }
}

/// The shared shape of every hardware page, from spec §6.2: title with vendor
/// mark, large primary value, primary chart, an optional secondary
/// visualisation, four key statistics, and a sticky *Full specifications*
/// disclosure.
///
/// Extracted so the five pages are identical by construction rather than by
/// five people remembering to keep them in step.
public struct HardwarePage<Secondary: View, Specs: View>: View {
    private let title: String
    private let vendorName: String?
    private let showsAppleMark: Bool
    private let primaryValue: String?
    private let series: [ChartSeries]
    private let stats: [HardwareStat]
    private let secondary: Secondary
    private let specifications: Specs

    /// `@SceneStorage`, not `@State`: `AppShell` rebuilds the page on every
    /// sidebar switch, which would reset plain state. The spec requires the
    /// disclosure to stay open once expanded, so it must survive teardown.
    @SceneStorage private var showFullSpecifications: Bool

    public init(
        title: String,
        vendorName: String?,
        showsAppleMark: Bool,
        primaryValue: String?,
        series: [ChartSeries],
        stats: [HardwareStat],
        disclosureKey: String,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder specifications: () -> Specs
    ) {
        self.title = title
        self.vendorName = vendorName
        self.showsAppleMark = showsAppleMark
        self.primaryValue = primaryValue
        self.series = series
        self.stats = stats
        self.secondary = secondary()
        self.specifications = specifications()
        self._showFullSpecifications = SceneStorage(wrappedValue: false, disclosureKey)
    }

    /// An absent primary reading shows an em dash. Never "0", never blank.
    public static func displayPrimary(_ value: String?) -> String {
        value ?? "—"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
                header

                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.displayPrimary(primaryValue))
                            .font(Vitals.Typography.readout)
                            .foregroundStyle(primaryValue == nil ? .secondary : .primary)

                        if !series.isEmpty {
                            MetricChart(
                                series: series,
                                style: .area(stacked: series.count > 1),
                                colors: Vitals.seriesColors(count: max(series.count, 1))
                            )
                        }

                        secondary
                    }
                }

                if !stats.isEmpty {
                    GlassPanel {
                        VStack(spacing: 0) {
                            ForEach(stats) { stat in
                                StatRow(label: stat.label, value: stat.value)
                            }
                        }
                    }
                }

                GlassPanel {
                    DisclosureGroup(isExpanded: $showFullSpecifications) {
                        VStack(spacing: 0) { specifications }
                            .padding(.top, 6)
                    } label: {
                        Text("Full specifications").font(Vitals.Typography.label)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(Vitals.Typography.sectionTitle)
            Spacer()
            if let vendorName {
                HStack(spacing: 6) {
                    // The Apple mark is a glyph in the system font, so no asset
                    // is bundled for it.
                    if showsAppleMark { Text("\u{F8FF}") }
                    Text(vendorName)
                }
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassSurface(cornerRadius: 20)
            }
        }
    }
}
```

- [ ] **Step 4: Refactor `CPUPage` onto the container**

Replace `CPUPage`'s `body`, `header`, `primaryValue`, `keyStatistics`, and `fullSpecifications` with a single `HardwarePage`. Keep every existing static helper (`formatCache`, `clusterSeries`, `formatUptime`) and their tests unchanged — they are pure and already covered.

The new `body`:

```swift
    public var body: some View {
        HardwarePage(
            title: "CPU",
            vendorName: topology?.brand,
            showsAppleMark: topology?.isAppleSilicon == true,
            primaryValue: store.cpu.map { "\(Int(($0.total * 100).rounded()))%" },
            series: topology.map { Self.clusterSeries(history: store.cpuHistory, topology: $0) } ?? [],
            stats: stats,
            disclosureKey: "CPUPage.showFullSpecifications"
        ) {
            coreGrid
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.cpu) }
    }

    private var stats: [HardwareStat] {
        let load = store.systemLoad
        return [
            HardwareStat(label: "Cores", value: coreCountDescription),
            HardwareStat(label: "Load average", value: load.loadAverage1.map { String(format: "%.2f", $0) }),
            HardwareStat(label: "Uptime", value: Self.formatUptime(load.uptimeSeconds)),
            HardwareStat(label: "Speed", value: nil),
        ]
    }
```

Keep `coreGrid` and move the disclosure's rows into a `specificationRows` view containing exactly the `StatRow`s that are there today. **Reuse the same `disclosureKey` string** so an already-expanded disclosure stays expanded across the refactor.

- [ ] **Step 5: Run the full suite**

Run: `cd VitalsCore && swift test`
Expected: PASS — all existing tests plus 5 new, non-zero count, no warnings. The existing `CPUPageTests` must pass **unchanged**; if one needs editing, the refactor changed behaviour and that is a defect, not a test problem.

- [ ] **Step 6: Confirm no visual regression**

Capture the CPU page and compare against the M1-B-1 appearance:

```bash
cd VitalsCore && swift build --product VitalsApp
"$(swift build --product VitalsApp --show-bin-path)/VitalsApp" &
sleep 8
PID=$(pgrep -n VitalsApp)
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set size of window 1 to {1200, 900}"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set selected of row 5 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true"
sleep 4
B=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get {position, size} of window 1")
R=$(echo "$B" | tr -d ' ' | awk -F, '{print $1","$2","$3","$4}')
screencapture -x -o -R"$R" /tmp/vitals-render/cpu-refactored.png
pkill VitalsApp
```

Read the PNG. It must still show the Apple mark and brand, a live percentage, the stacked chart, the ten-bar core grid, four stats, and the collapsed disclosure. Report anything that moved.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages VitalsCore/Tests/VitalsUITests/HardwarePageTests.swift
git commit -m "refactor: extract shared HardwarePage container from CPUPage"
```

---

### Task 2: Store support for the GPU, storage, and network series

`MetricsStore.apply` currently ignores `.gpu`, `.storage`, and `.network` — it returns early for them. Pages cannot show data the store discards.

**Files:**
- Modify: `VitalsCore/Sources/SystemMetrics/Memory/MemorySample.swift`
- Modify: `VitalsCore/Sources/SystemMetrics/Memory/MemoryHardware.swift`
- Modify: `VitalsCore/Sources/SystemMetrics/GPU/GPUSample.swift`
- Modify: `VitalsCore/Sources/VitalsUI/MetricsStore.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `Timestamped`, `MetricValue`, `SeriesKey`.
- Produces: public memberwise initializers on `MemorySample`, `MemorySlot`, `GPUSample`, and `GPUDevice`; on `MetricsStore` — `gpu: [GPUSample]?`, `gpuHistory: [Timestamped<[GPUSample]>]`, `volumes: [Volume]?`, `network: [String: NetworkThroughput]?`, `networkHistory: [Timestamped<[String: NetworkThroughput]>]`. Tasks 5–7 read these.

**Design note:** volumes get no history — capacity changes over minutes, not seconds, and a 600-sample ring of near-identical values is waste. GPU and network do, because their charts need it.

- [ ] **Step 1: Add the public initializers the tests need**

`MemorySample`, `MemorySlot`, `GPUSample`, and `GPUDevice` have only the synthesised memberwise initializer, which is internal to `SystemMetrics`. `VitalsUITests` therefore cannot construct any of them, and the fixtures in this task and in Tasks 4 and 5 will not compile without this. (`Volume` and `NetworkThroughput` already have public initializers.)

Add an explicit `public init` to each, taking every stored property in declaration order and assigning it. For example, in `VitalsCore/Sources/SystemMetrics/GPU/GPUSample.swift`:

```swift
    public init(
        deviceUtilisation: Double?,
        rendererUtilisation: Double?,
        tilerUtilisation: Double?,
        inUseMemoryBytes: UInt64?,
        allocatedMemoryBytes: UInt64?
    ) {
        self.deviceUtilisation = deviceUtilisation
        self.rendererUtilisation = rendererUtilisation
        self.tilerUtilisation = tilerUtilisation
        self.inUseMemoryBytes = inUseMemoryBytes
        self.allocatedMemoryBytes = allocatedMemoryBytes
    }
```

Do the same for `MemorySample` (`app`, `wired`, `compressed`, `cached`, `free`, `swapUsed`, `swapTotal`, `pressure`), `MemorySlot` (`name`, `sizeDescription`, `type`, `speedMHz`, `manufacturer`, `partNumber`), and `GPUDevice` (`name`, `topology`, `coreCount`).

**Then verify nothing in-module broke.** An explicit initializer suppresses the synthesised one, so any existing caller relying on a different argument order stops compiling:

Run: `cd VitalsCore && swift test --filter SystemMetricsTests`
Expected: PASS, non-zero count. If a caller breaks, fix the caller — do not reorder the initializer to match it, because declaration order is what a reader expects.

- [ ] **Step 2: Write the failing test**

Append to `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`, inside the existing `@Suite`:

```swift
    @Test("publishes GPU samples with history")
    func publishesGPU() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let sample = GPUSample(
            deviceUtilisation: 0.4, rendererUtilisation: 0.3,
            tilerUtilisation: 0.1, inUseMemoryBytes: 1000, allocatedMemoryBytes: 2000
        )
        await engine.register(AnySampler { [sample] }, for: .gpu, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.gpu) }
        try await waitUntil { store.gpuHistory.count >= 2 }
        task.cancel()

        #expect(store.gpu?.first?.deviceUtilisation == 0.4)
        #expect(store.gpuHistory.isEmpty == false)
    }

    @Test("publishes volumes without retaining history")
    func publishesVolumesWithoutHistory() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let volume = Volume(name: "Macintosh HD", totalBytes: 1000, availableBytes: 400, isInternal: true)
        await engine.register(AnySampler { [volume] }, for: .storage, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.storage) }
        try await waitUntil { store.volumes != nil }
        task.cancel()

        // Capacity moves over minutes; a 600-sample ring of identical values
        // would be waste, so only the latest reading is kept.
        #expect(store.volumes?.first?.name == "Macintosh HD")
    }

    @Test("publishes network throughput with history")
    func publishesNetwork() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let throughput = ["en0": NetworkThroughput(bytesInPerSecond: 2048, bytesOutPerSecond: 1024)]
        await engine.register(AnySampler { throughput }, for: .network, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.network) }
        try await waitUntil { store.networkHistory.count >= 2 }
        task.cancel()

        #expect(store.network?["en0"]?.bytesInPerSecond == 2048)
    }

    @Test("a wrong-typed payload on a new series is ignored, not crashed on")
    func wrongTypeOnNewSeriesIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a GPU sample" }, for: .gpu, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.gpu) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.gpu == nil)
        #expect(store.gpuHistory.isEmpty)
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: FAIL — `value of type 'MetricsStore' has no member 'gpuHistory'`.

- [ ] **Step 4: Extend the store**

In `VitalsCore/Sources/VitalsUI/MetricsStore.swift`, add these properties beside the existing ones:

```swift
    public private(set) var gpu: [GPUSample]?
    public private(set) var gpuHistory: [Timestamped<[GPUSample]>] = []

    /// Latest only — volume capacity changes over minutes, not seconds, so a
    /// 600-sample ring of near-identical readings would be pure waste.
    public private(set) var volumes: [Volume]?

    public private(set) var network: [String: NetworkThroughput]?
    public private(set) var networkHistory: [Timestamped<[String: NetworkThroughput]>] = []
```

Replace the `case .gpu, .storage, .network, .processes:` arm of `apply(_:for:)` with:

```swift
        case .gpu:
            guard let samples = value.value as? [GPUSample] else { return }
            gpu = samples
            append(Timestamped(timestamp: value.timestamp, sample: samples), to: &gpuHistory)
        case .storage:
            guard let latest = value.value as? [Volume] else { return }
            volumes = latest
        case .network:
            guard let throughput = value.value as? [String: NetworkThroughput] else { return }
            network = throughput
            append(Timestamped(timestamp: value.timestamp, sample: throughput), to: &networkHistory)
        case .processes:
            // The Processes pane is M1-B-3. Ignored rather than crashed on, so
            // a page that subscribes early does not fault.
            return
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: PASS — 11 tests, non-zero count.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/MetricsStore.swift VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift
git commit -m "feat: publish GPU, storage and network series from the store"
```

---

### Task 3: Wire the disk I/O series

`StorageSampler.ioCounters()` was built and tested in M1-A and never connected to anything. The spec requires a Read/Write throughput chart on the Storage page (§6.3), and this is its missing data source.

**Files:**
- Modify: `VitalsCore/Sources/MetricsEngine/SeriesKey.swift`
- Modify: `VitalsCore/Sources/MetricsEngine/StandardSamplers.swift`
- Modify: `VitalsCore/Sources/VitalsUI/MetricsStore.swift`
- Test: `VitalsCore/Tests/MetricsEngineTests/DiskIOSamplerTests.swift`

**Interfaces:**
- Consumes: `StorageSampler.ioCounters()`, `DeltaCounter`, `SamplerState`.
- Produces: `SeriesKey.diskIO`; `DiskThroughput` (`bytesReadPerSecond: Double`, `bytesWrittenPerSecond: Double`); the `.diskIO` payload type `[String: DiskThroughput]`; on the store, `diskIO: [String: DiskThroughput]?` and `diskIOHistory: [Timestamped<[String: DiskThroughput]>]`. Task 6 reads these.

**Note:** adding a `SeriesKey` case makes `OverheadTests.staysUnderBudget` assert that all *seven* series produce samples, so forgetting to register the sampler will fail that test rather than passing silently. That is deliberate.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/MetricsEngineTests/DiskIOSamplerTests.swift`:

```swift
import Foundation
import SystemMetrics
import Testing
@testable import MetricsEngine

@Suite("Disk IO")
struct DiskIOSamplerTests {

    @Test("diskIO is one of the standard series")
    func diskIOIsAStandardSeries() {
        #expect(SeriesKey.allCases.contains(.diskIO))
    }

    @Test("the first reading yields no throughput, because there is nothing to subtract from")
    func firstReadingYieldsNothing() {
        var tracker = DiskThroughputTracker()
        let counters = ["disk0": StorageIOCounters(bytesRead: 1000, bytesWritten: 500)]
        #expect(tracker.update(counters, at: 10).isEmpty)
    }

    @Test("the second reading yields per-second rates")
    func secondReadingYieldsRates() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk0": StorageIOCounters(bytesRead: 1000, bytesWritten: 500)], at: 10)
        let result = tracker.update(["disk0": StorageIOCounters(bytesRead: 3000, bytesWritten: 1500)], at: 12)

        #expect(result["disk0"]?.bytesReadPerSecond == 1000)
        #expect(result["disk0"]?.bytesWrittenPerSecond == 500)
    }

    @Test("devices are tracked independently")
    func devicesTrackedIndependently() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update([
            "disk0": StorageIOCounters(bytesRead: 0, bytesWritten: 0),
            "disk4": StorageIOCounters(bytesRead: 0, bytesWritten: 0),
        ], at: 10)
        let result = tracker.update([
            "disk0": StorageIOCounters(bytesRead: 100, bytesWritten: 0),
            "disk4": StorageIOCounters(bytesRead: 900, bytesWritten: 0),
        ], at: 11)

        #expect(result["disk0"]?.bytesReadPerSecond == 100)
        #expect(result["disk4"]?.bytesReadPerSecond == 900)
    }

    @Test("a device appearing mid-stream produces no rate on its first sample")
    func appearingDeviceHasNoRate() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk0": StorageIOCounters(bytesRead: 0, bytesWritten: 0)], at: 10)
        let result = tracker.update([
            "disk0": StorageIOCounters(bytesRead: 100, bytesWritten: 0),
            "disk9": StorageIOCounters(bytesRead: 5000, bytesWritten: 0),
        ], at: 11)

        #expect(result["disk0"] != nil)
        #expect(result["disk9"] == nil)
    }

    @Test("a counter reset is dropped rather than reported as a burst")
    func counterResetIsDropped() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk0": StorageIOCounters(bytesRead: 9_000_000, bytesWritten: 0)], at: 10)
        let result = tracker.update(["disk0": StorageIOCounters(bytesRead: 40, bytesWritten: 0)], at: 11)
        #expect(result["disk0"] == nil)
    }

    @Test("a device that goes away is forgotten, so a later return starts fresh")
    func departedDeviceIsForgotten() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk4": StorageIOCounters(bytesRead: 9000, bytesWritten: 0)], at: 10)
        _ = tracker.update([:], at: 11)
        let result = tracker.update(["disk4": StorageIOCounters(bytesRead: 20, bytesWritten: 0)], at: 12)

        // Without forgetting, this would report a huge negative-turned-dropped
        // delta against a stale reading from before the device was unplugged.
        #expect(result["disk4"] == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter DiskIOSamplerTests`
Expected: FAIL — `type 'SeriesKey' has no member 'diskIO'`.

- [ ] **Step 3: Add the series key and throughput type**

In `VitalsCore/Sources/MetricsEngine/SeriesKey.swift`, add `case diskIO` to `SeriesKey`, and append:

```swift
/// Read and write throughput for one block device, in bytes per second.
public struct DiskThroughput: Sendable, Equatable {
    public let bytesReadPerSecond: Double
    public let bytesWrittenPerSecond: Double

    public init(bytesReadPerSecond: Double, bytesWrittenPerSecond: Double) {
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
    }
}

/// Turns cumulative per-device byte counters into throughput.
///
/// One `DeltaCounter` per device per direction, mirroring
/// `NetworkThroughputTracker`: devices come and go (external drives, disk
/// images), and a shared counter would let one device's disappearance corrupt
/// another's rate.
public struct DiskThroughputTracker: Sendable {
    private var read: [String: DeltaCounter<UInt64>] = [:]
    private var written: [String: DeltaCounter<UInt64>] = [:]

    public init() {}

    public mutating func update(
        _ counters: [String: StorageIOCounters],
        at timestamp: TimeInterval
    ) -> [String: DiskThroughput] {
        var result: [String: DiskThroughput] = [:]

        for (device, counter) in counters {
            var readCounter = read[device] ?? DeltaCounter<UInt64>()
            var writeCounter = written[device] ?? DeltaCounter<UInt64>()

            let readDelta = readCounter.update(counter.bytesRead, at: timestamp)
            let writeDelta = writeCounter.update(counter.bytesWritten, at: timestamp)

            read[device] = readCounter
            written[device] = writeCounter

            // Both directions must be valid; a reset on either invalidates the
            // interval for this device rather than reporting half a reading.
            if let readDelta, let writeDelta {
                result[device] = DiskThroughput(
                    bytesReadPerSecond: readDelta.perSecond,
                    bytesWrittenPerSecond: writeDelta.perSecond
                )
            }
        }

        // Forget departed devices so a reappearance starts fresh instead of
        // producing a huge delta against a stale reading.
        read = read.filter { counters.keys.contains($0.key) }
        written = written.filter { counters.keys.contains($0.key) }

        return result
    }
}
```

`SeriesKey.swift` will need `import SystemMetrics` for `StorageIOCounters` if it does not already have it.

- [ ] **Step 4: Register the sampler**

In `VitalsCore/Sources/MetricsEngine/StandardSamplers.swift`, add to `registerAll(on:)`:

```swift
        await engine.register(diskIOSampler(), for: .diskIO, cadence: .fast)
```

and add the sampler beside the others:

```swift
    private static func diskIOSampler() -> AnySampler {
        let tracker = SamplerState(DiskThroughputTracker())
        return AnySampler {
            let counters = StorageSampler.ioCounters()
            let now = ProcessInfo.processInfo.systemUptime
            let throughput = tracker.withLock { $0.update(counters, at: now) }
            guard !throughput.isEmpty else { throw SamplerError.unavailable }
            return throughput
        }
    }
```

- [ ] **Step 5: Add store support**

In `VitalsCore/Sources/VitalsUI/MetricsStore.swift`, add:

```swift
    public private(set) var diskIO: [String: DiskThroughput]?
    public private(set) var diskIOHistory: [Timestamped<[String: DiskThroughput]>] = []
```

and a `case .diskIO:` arm in `apply(_:for:)`:

```swift
        case .diskIO:
            guard let throughput = value.value as? [String: DiskThroughput] else { return }
            diskIO = throughput
            append(Timestamped(timestamp: value.timestamp, sample: throughput), to: &diskIOHistory)
```

- [ ] **Step 6: Run the full suite**

Run: `cd VitalsCore && swift test`
Expected: PASS — including `OverheadTests.staysUnderBudget`, which now requires all seven series to produce samples. If it reports fewer than seven, the sampler is not registered.

- [ ] **Step 7: Confirm real throughput on this machine**

Run: `cd VitalsCore && swift run vitals-dump 2>&1 | head -40`

`OverheadTests.staysUnderBudget` now requires every one of the seven series to
produce at least one sample, so it fails outright if `.diskIO` is not sampling.
Run it while generating disk activity, so the series sees real non-zero traffic
rather than an idle disk:

```bash
find / -name "*.swift" > /dev/null 2>&1 &
cd VitalsCore && swift test --filter OverheadTests
```

Expected: PASS, with the overhead figure printed. Report the figure and confirm
the run did not report "Only N of 7 series produced samples".

- [ ] **Step 8: Commit**

```bash
git add VitalsCore/Sources/MetricsEngine VitalsCore/Sources/VitalsUI/MetricsStore.swift VitalsCore/Tests/MetricsEngineTests/DiskIOSamplerTests.swift
git commit -m "feat: wire disk IO counters into a throughput series"
```

---

### Task 4: Memory page

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/MemoryPage.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Shell/SidebarSection.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MemoryPageTests.swift`

**Interfaces:**
- Consumes: `HardwarePage`, `HardwareStat`, `MetricsStore.memory`/`memoryHistory`/`profile`.
- Produces: `MemoryPage`; `MemoryPage.breakdownSeries(history:installedBytes:) -> [ChartSeries]`; `MemoryPage.formatBytes(_:) -> String?`.

**The honest-reporting case this page carries.** Apple Silicon exposes no memory clock, so `MemoryHardware.speedMHz` is `nil` there and the page must show the SoC's spec bandwidth *labelled as a specification*, never a fabricated MHz. Intel Macs do expose real per-DIMM speeds. This is spec §4.2 arriving on screen.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/MemoryPageTests.swift`:

```swift
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Memory page")
struct MemoryPageTests {

    private static func sample(app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64) -> MemorySample {
        MemorySample(
            app: app, wired: wired, compressed: compressed, cached: cached,
            free: 0, swapUsed: nil, swapTotal: nil, pressure: nil
        )
    }

    private static func stamped(_ samples: [MemorySample]) -> [Timestamped<MemorySample>] {
        samples.enumerated().map { Timestamped(timestamp: 1000 + TimeInterval($0.offset), sample: $0.element) }
    }

    @Test("decomposes into the four bands the spec names, base first")
    func decomposesIntoFourBands() {
        let history = Self.stamped([Self.sample(app: 30, wired: 20, compressed: 10, cached: 40)])
        let series = MemoryPage.breakdownSeries(history: history, installedBytes: 100)

        #expect(series.map(\.name) == ["Wired", "App", "Compressed", "Cached"])
        #expect(series[0].values == [0.2])
        #expect(series[1].values == [0.3])
    }

    @Test("bands carry timestamps so gaps still break")
    func bandsCarryTimestamps() {
        let history = Self.stamped([
            Self.sample(app: 30, wired: 20, compressed: 10, cached: 40),
            Self.sample(app: 30, wired: 20, compressed: 10, cached: 40),
        ])
        let series = MemoryPage.breakdownSeries(history: history, installedBytes: 100)
        #expect(series[0].timestamps == [1000, 1001])
    }

    @Test("no installed total means no bands, rather than dividing by zero")
    func zeroInstalledYieldsNoBands() {
        let history = Self.stamped([Self.sample(app: 30, wired: 20, compressed: 10, cached: 40)])
        #expect(MemoryPage.breakdownSeries(history: history, installedBytes: 0).isEmpty)
    }

    @Test("empty history yields no bands")
    func emptyHistoryYieldsNoBands() {
        #expect(MemoryPage.breakdownSeries(history: [], installedBytes: 100).isEmpty)
    }

    @Test("an absent byte count formats as nil, letting StatRow word the absence")
    func absentBytesFormatAsNil() {
        #expect(MemoryPage.formatBytes(nil) == nil)
        #expect(MemoryPage.formatBytes(1_073_741_824)?.isEmpty == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter MemoryPageTests`
Expected: FAIL — `cannot find 'MemoryPage' in scope`.

- [ ] **Step 3: Write the page**

Create `VitalsCore/Sources/VitalsUI/Pages/MemoryPage.swift`:

```swift
import SwiftUI
import SystemMetrics

public struct MemoryPage: View {
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// `nil` rather than a literal string, so `StatRow` decides how absence is
    /// worded — the house rule established by `CPUPage.formatCache`.
    public static func formatBytes(_ bytes: UInt64?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// The four bands from spec §6.3, as fractions of installed memory.
    ///
    /// Base first: Wired is the floor the kernel will not give back, App sits
    /// on it, then Compressed, then Cached.
    public static func breakdownSeries(
        history: [Timestamped<MemorySample>],
        installedBytes: UInt64
    ) -> [ChartSeries] {
        guard !history.isEmpty, installedBytes > 0 else { return [] }

        let total = Double(installedBytes)
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (MemorySample) -> UInt64) -> ChartSeries {
            ChartSeries(
                name: name,
                values: history.map { Double(value($0.sample)) / total },
                timestamps: timestamps
            )
        }

        return [
            band("Wired") { $0.wired },
            band("App") { $0.app },
            band("Compressed") { $0.compressed },
            band("Cached") { $0.cached },
        ]
    }

    // MARK: View

    private var hardware: MemoryHardware? { store.profile?.memory }

    public var body: some View {
        HardwarePage(
            title: "Memory",
            vendorName: hardware.map { Self.formatBytes($0.totalBytes) ?? "Memory" },
            showsAppleMark: hardware?.isUnified == true,
            primaryValue: store.memory.flatMap { Self.formatBytes($0.used) },
            series: hardware.map {
                Self.breakdownSeries(history: store.memoryHistory, installedBytes: $0.totalBytes)
            } ?? [],
            stats: stats,
            disclosureKey: "MemoryPage.showFullSpecifications"
        ) {
            EmptyView()
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.memory) }
    }

    private var stats: [HardwareStat] {
        [
            HardwareStat(label: "Installed", value: Self.formatBytes(hardware?.totalBytes)),
            HardwareStat(label: "Cached files", value: Self.formatBytes(store.memory?.cached)),
            HardwareStat(label: "Swap used", value: Self.formatBytes(store.memory?.swapUsed)),
            HardwareStat(label: "Pressure", value: store.memory?.pressure.map(Self.describe)),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        StatRow(label: "Type", value: hardware?.type)
        StatRow(label: "Manufacturer", value: hardware?.manufacturer)
        StatRow(label: "Unified", value: hardware.map { $0.isUnified ? "Yes" : "No" })
        // Apple Silicon exposes no memory clock. Showing the SoC's published
        // bandwidth — explicitly labelled a specification — is honest; a
        // fabricated MHz figure would not be. Intel Macs report real per-DIMM
        // speeds, and get the speed row instead.
        StatRow(label: "Speed", value: hardware?.speedMHz.map { "\($0) MHz" })
        StatRow(
            label: "Peak bandwidth",
            value: hardware?.peakBandwidthGBs.map { "\($0) GB/s (specification)" }
        )
        StatRow(label: "Wired", value: Self.formatBytes(store.memory?.wired))
        StatRow(label: "Compressed", value: Self.formatBytes(store.memory?.compressed))
        ForEach(hardware?.slots ?? [], id: \.name) { slot in
            StatRow(
                label: slot.name,
                value: [slot.sizeDescription, slot.type, slot.speedMHz.map { "\($0) MHz" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
        }
    }

    private static func describe(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}
```

- [ ] **Step 4: Route it in the shell**

In `VitalsCore/Sources/VitalsUI/Shell/SidebarSection.swift`, add `.memory` to the `isImplemented` true-arm:

```swift
    public var isImplemented: Bool {
        switch self {
        case .overview, .cpu, .memory: true
        default: false
        }
    }
```

In `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`, add to the `detail` switch:

```swift
        case .memory:
            MemoryPage(store: store)
```

Update `SidebarSectionTests.implementedSectionsAreMarked` to expect `.memory` implemented.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VitalsCore && swift test`
Expected: PASS — 5 new tests, non-zero count, no warnings.

- [ ] **Step 6: Capture the page**

Use the capture recipe from Task 1, Step 6, selecting **row 6** instead of row 5 (`Memory` follows `CPU`). Read the PNG. Confirm four stacked bands, a live used-memory figure, and — in *Full specifications* — that **Speed reads "Unavailable" on this Apple Silicon machine while Peak bandwidth reads "200.0 GB/s (specification)"**. That contrast is the whole point of the page; report exactly what you see.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests
git commit -m "feat: add Memory page with wired/app/compressed/cached breakdown"
```

---

### Task 5: GPU page

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/GPUPage.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`, `Shell/SidebarSection.swift`
- Test: `VitalsCore/Tests/VitalsUITests/GPUPageTests.swift`

**Interfaces:**
- Consumes: `HardwarePage`, `MetricsStore.gpu`/`gpuHistory`/`profile`.
- Produces: `GPUPage`; `GPUPage.engineSeries(history:) -> [ChartSeries]`; `GPUPage.describeMemory(_:) -> String`.

**The optional-handling case this page carries.** Every field on `GPUSample` is `Optional` because which keys a driver publishes varies. A driver that does not report tiler utilisation must have that band **omitted**, not drawn as a flat 0% line.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/GPUPageTests.swift`:

```swift
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("GPU page")
struct GPUPageTests {

    private static func stamped(_ samples: [[GPUSample]]) -> [Timestamped<[GPUSample]>] {
        samples.enumerated().map { Timestamped(timestamp: 1000 + TimeInterval($0.offset), sample: $0.element) }
    }

    private static func sample(renderer: Double?, tiler: Double?) -> GPUSample {
        GPUSample(
            deviceUtilisation: 0.5, rendererUtilisation: renderer,
            tilerUtilisation: tiler, inUseMemoryBytes: nil, allocatedMemoryBytes: nil
        )
    }

    @Test("splits into the renderer and tiler bands the spec names")
    func splitsIntoEngineBands() {
        let history = Self.stamped([[Self.sample(renderer: 0.3, tiler: 0.2)]])
        let series = GPUPage.engineSeries(history: history)

        #expect(series.map(\.name) == ["Renderer", "Tiler"])
        #expect(series[0].values == [0.3])
        #expect(series[1].values == [0.2])
    }

    @Test("an engine the driver does not report is omitted, never drawn as a flat zero")
    func unreportedEngineIsOmitted() {
        // A 0% band would be a measurement this driver never made.
        let history = Self.stamped([[Self.sample(renderer: 0.3, tiler: nil)]])
        let series = GPUPage.engineSeries(history: history)

        #expect(series.map(\.name) == ["Renderer"])
    }

    @Test("a driver reporting neither engine yields no bands at all")
    func noEnginesYieldsNoBands() {
        let history = Self.stamped([[Self.sample(renderer: nil, tiler: nil)]])
        #expect(GPUPage.engineSeries(history: history).isEmpty)
    }

    @Test("bands carry timestamps so gaps still break")
    func bandsCarryTimestamps() {
        let history = Self.stamped([
            [Self.sample(renderer: 0.3, tiler: 0.2)],
            [Self.sample(renderer: 0.4, tiler: 0.1)],
        ])
        #expect(GPUPage.engineSeries(history: history)[0].timestamps == [1000, 1001])
    }

    @Test("empty history yields no bands")
    func emptyHistoryYieldsNoBands() {
        #expect(GPUPage.engineSeries(history: []).isEmpty)
    }

    @Test("each memory topology is described distinctly, never flattened")
    func memoryTopologiesAreDistinct() {
        // The three cases mean different things to a reader and must not read
        // identically.
        let unified = GPUPage.describeMemory(.unified(systemBytes: 17_179_869_184))
        let dedicated = GPUPage.describeMemory(.dedicated(vramBytes: 8_589_934_592))
        let shared = GPUPage.describeMemory(.shared(maxSharedBytes: 4_294_967_296))

        #expect(unified.contains("nified"))
        #expect(dedicated.contains("VRAM"))
        #expect(shared.contains("hared"))
        #expect(Set([unified, dedicated, shared]).count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter GPUPageTests`
Expected: FAIL — `cannot find 'GPUPage' in scope`.

- [ ] **Step 3: Write the page**

Create `VitalsCore/Sources/VitalsUI/Pages/GPUPage.swift`:

```swift
import SwiftUI
import SystemMetrics

public struct GPUPage: View {
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// Renderer and tiler utilisation, per spec §6.3.
    ///
    /// Both fields are optional because which keys a driver publishes varies.
    /// An engine the driver never reported is omitted entirely — a flat 0%
    /// band would claim a measurement that was never taken.
    public static func engineSeries(history: [Timestamped<[GPUSample]>]) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (GPUSample) -> Double?) -> ChartSeries? {
            let values = history.compactMap { entry in entry.sample.first.flatMap(value) }
            guard values.count == history.count else { return nil }
            return ChartSeries(name: name, values: values, timestamps: timestamps)
        }

        return [
            band("Renderer") { $0.rendererUtilisation },
            band("Tiler") { $0.tilerUtilisation },
        ].compactMap { $0 }
    }

    /// The three memory topologies mean different things to a reader — one
    /// pool shared with the CPU, a card's own VRAM, or a slice carved out of
    /// system RAM — so each is worded distinctly rather than flattened into a
    /// byte count.
    public static func describeMemory(_ topology: GPUMemoryTopology) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory

        switch topology {
        case .unified(let bytes):
            return "\(formatter.string(fromByteCount: Int64(bytes))) unified"
        case .dedicated(let bytes):
            return "\(formatter.string(fromByteCount: Int64(bytes))) dedicated VRAM"
        case .shared(let bytes):
            return "\(formatter.string(fromByteCount: Int64(bytes))) shared with system"
        }
    }

    // MARK: View

    private var device: GPUDevice? { store.profile?.gpus.first }
    private var latest: GPUSample? { store.gpu?.first }

    public var body: some View {
        HardwarePage(
            title: "GPU",
            vendorName: device?.name,
            showsAppleMark: store.profile?.cpu.isAppleSilicon == true,
            primaryValue: latest?.deviceUtilisation.map { "\(Int(($0 * 100).rounded()))%" },
            series: Self.engineSeries(history: store.gpuHistory),
            stats: stats,
            disclosureKey: "GPUPage.showFullSpecifications"
        ) {
            EmptyView()
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.gpu) }
    }

    private static func formatBytes(_ bytes: UInt64?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var stats: [HardwareStat] {
        [
            HardwareStat(label: "Memory", value: device.map { Self.describeMemory($0.topology) }),
            HardwareStat(label: "In use", value: Self.formatBytes(latest?.inUseMemoryBytes)),
            HardwareStat(label: "Allocated", value: Self.formatBytes(latest?.allocatedMemoryBytes)),
            HardwareStat(
                label: "Renderer",
                value: latest?.rendererUtilisation.map { "\(Int(($0 * 100).rounded()))%" }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        StatRow(label: "Device", value: device?.name)
        StatRow(label: "Cores", value: device?.coreCount.map(String.init))
        StatRow(label: "Tiler", value: latest?.tilerUtilisation.map { "\(Int(($0 * 100).rounded()))%" })
        // Per-process GPU usage needs powermetrics behind the privileged
        // helper, which is milestone M3.
        StatRow(label: "Per-process usage", value: nil)
        ForEach(Array((store.profile?.gpus ?? []).enumerated()), id: \.offset) { index, gpu in
            StatRow(label: "GPU \(index + 1)", value: "\(gpu.name) · \(Self.describeMemory(gpu.topology))")
        }
    }
}
```

- [ ] **Step 4: Route it in the shell**

Add `.gpu` to `SidebarSection.isImplemented`'s true-arm and a `case .gpu: GPUPage(store: store)` arm to `AppShell.detail`. Update `SidebarSectionTests` accordingly.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VitalsCore && swift test`
Expected: PASS — 6 new tests, non-zero count, no warnings.

- [ ] **Step 6: Capture the page**

Capture recipe from Task 1 Step 6, selecting **row 7**. Confirm the device name, a live utilisation percentage, renderer/tiler bands, and that Memory reads "16 GB unified" on this machine. Report what you see.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests
git commit -m "feat: add GPU page with renderer/tiler engine breakdown"
```

---

### Task 6: Storage page

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/StoragePage.swift`
- Create: `VitalsCore/Sources/VitalsUI/Components/VolumeBar.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`, `Shell/SidebarSection.swift`
- Test: `VitalsCore/Tests/VitalsUITests/StoragePageTests.swift`

**Interfaces:**
- Consumes: `HardwarePage`, `MetricsStore.volumes`/`diskIO`/`diskIOHistory`, `DiskThroughput`.
- Produces: `StoragePage`; `StoragePage.throughputSeries(history:) -> [ChartSeries]`; `VolumeBar` view.

This is the page whose secondary visualisation is a set of volume capacity bars, per spec §6.2.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/StoragePageTests.swift`:

```swift
import MetricsEngine
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Storage page")
struct StoragePageTests {

    private static func stamped(
        _ samples: [[String: DiskThroughput]]
    ) -> [Timestamped<[String: DiskThroughput]>] {
        samples.enumerated().map { Timestamped(timestamp: 1000 + TimeInterval($0.offset), sample: $0.element) }
    }

    @Test("splits into read and write bands, in megabytes per second")
    func splitsIntoReadAndWrite() {
        let history = Self.stamped([
            ["disk0": DiskThroughput(bytesReadPerSecond: 2_097_152, bytesWrittenPerSecond: 1_048_576)]
        ])
        let series = StoragePage.throughputSeries(history: history)

        #expect(series.map(\.name) == ["Read", "Write"])
        #expect(series[0].values == [2.0])
        #expect(series[1].values == [1.0])
    }

    @Test("throughput is absolute, so a value below 1 is not read back as a percentage")
    func throughputUnitIsAbsolute() {
        let history = Self.stamped([
            ["disk0": DiskThroughput(bytesReadPerSecond: 524_288, bytesWrittenPerSecond: 0)]
        ])
        let series = StoragePage.throughputSeries(history: history)
        #expect(series[0].unit == .absolute(suffix: "MB/s"))
    }

    @Test("throughput across several devices is summed")
    func throughputIsSummedAcrossDevices() {
        let history = Self.stamped([[
            "disk0": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
            "disk4": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
        ]])
        #expect(StoragePage.throughputSeries(history: history)[0].values == [2.0])
    }

    @Test("bands carry timestamps so gaps still break")
    func bandsCarryTimestamps() {
        let history = Self.stamped([
            ["disk0": DiskThroughput(bytesReadPerSecond: 0, bytesWrittenPerSecond: 0)],
            ["disk0": DiskThroughput(bytesReadPerSecond: 0, bytesWrittenPerSecond: 0)],
        ])
        #expect(StoragePage.throughputSeries(history: history)[0].timestamps == [1000, 1001])
    }

    @Test("empty history yields no bands")
    func emptyHistoryYieldsNoBands() {
        #expect(StoragePage.throughputSeries(history: []).isEmpty)
    }

    @Test("renders a volume bar")
    func rendersVolumeBar() throws {
        let bar = VolumeBar(
            volume: Volume(name: "Macintosh HD", totalBytes: 1000, availableBytes: 250, isInternal: true),
            accent: Vitals.Palette.storage
        )
        let url = try renderPNG(bar, size: CGSize(width: 400, height: 60), named: "volume-bar")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter StoragePageTests`
Expected: FAIL — `cannot find 'StoragePage' in scope`.

- [ ] **Step 3: Write the volume bar**

Create `VitalsCore/Sources/VitalsUI/Components/VolumeBar.swift`:

```swift
import SwiftUI
import SystemMetrics

/// One volume's capacity as a labelled bar.
public struct VolumeBar: View {
    private let volume: Volume
    private let accent: Color

    public init(volume: Volume, accent: Color) {
        self.volume = volume
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(volume.name).font(Vitals.Typography.label)
                Spacer()
                Text("\(Self.format(volume.usedBytes)) of \(Self.format(volume.totalBytes))")
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule()
                        .fill(accent)
                        .frame(width: proxy.size.width * volume.usedFraction)
                }
            }
            .frame(height: 8)
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
```

- [ ] **Step 4: Write the page**

Create `VitalsCore/Sources/VitalsUI/Pages/StoragePage.swift`:

```swift
import MetricsEngine
import SwiftUI
import SystemMetrics

public struct StoragePage: View {
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    private static let bytesPerMegabyte = 1_048_576.0

    /// Read and write throughput per spec §6.3, summed across every device and
    /// expressed in MB/s.
    ///
    /// The unit is declared rather than inferred: a read rate of 0.05 MB/s must
    /// never be read back as "5%" because it happens to be below 1.
    public static func throughputSeries(
        history: [Timestamped<[String: DiskThroughput]>]
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (DiskThroughput) -> Double) -> ChartSeries {
            ChartSeries(
                name: name,
                values: history.map { entry in
                    entry.sample.values.reduce(0) { $0 + value($1) } / bytesPerMegabyte
                },
                timestamps: timestamps,
                unit: .absolute(suffix: "MB/s")
            )
        }

        return [
            band("Read") { $0.bytesReadPerSecond },
            band("Write") { $0.bytesWrittenPerSecond },
        ]
    }

    // MARK: View

    private var volumes: [Volume] { store.volumes ?? [] }

    private var totalThroughput: Double? {
        store.diskIO.map { devices in
            devices.values.reduce(0) { $0 + $1.bytesReadPerSecond + $1.bytesWrittenPerSecond }
                / Self.bytesPerMegabyte
        }
    }

    public var body: some View {
        HardwarePage(
            title: "Storage",
            vendorName: volumes.first(where: \.isInternal)?.name,
            showsAppleMark: false,
            primaryValue: totalThroughput.map { String(format: "%.2f MB/s", $0) },
            series: Self.throughputSeries(history: store.diskIOHistory),
            stats: stats,
            disclosureKey: "StoragePage.showFullSpecifications"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(volumes, id: \.name) { volume in
                    VolumeBar(volume: volume, accent: Vitals.Palette.storage)
                }
            }
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.storage) }
        .task { await store.stream(.diskIO) }
    }

    private static func formatBytes(_ bytes: UInt64?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var stats: [HardwareStat] {
        let boot = volumes.first(where: \.isInternal)
        return [
            HardwareStat(label: "Volumes", value: volumes.isEmpty ? nil : "\(volumes.count)"),
            HardwareStat(label: "Capacity", value: Self.formatBytes(boot?.totalBytes)),
            HardwareStat(label: "Available", value: Self.formatBytes(boot?.availableBytes)),
            HardwareStat(
                label: "Read",
                value: store.diskIO.map { devices in
                    String(
                        format: "%.2f MB/s",
                        devices.values.reduce(0) { $0 + $1.bytesReadPerSecond } / Self.bytesPerMegabyte
                    )
                }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        ForEach(volumes, id: \.name) { volume in
            StatRow(
                label: volume.name,
                value: "\(Self.formatBytes(volume.usedBytes) ?? "—") used of \(Self.formatBytes(volume.totalBytes) ?? "—")"
            )
        }
        ForEach(Array((store.diskIO ?? [:]).keys.sorted()), id: \.self) { device in
            StatRow(
                label: device,
                value: (store.diskIO?[device]).map {
                    String(
                        format: "%.2f read · %.2f write MB/s",
                        $0.bytesReadPerSecond / Self.bytesPerMegabyte,
                        $0.bytesWrittenPerSecond / Self.bytesPerMegabyte
                    )
                }
            )
        }
        // SMART health needs the privileged helper — milestone M3.
        StatRow(label: "SMART health", value: nil)
    }
}
```

- [ ] **Step 5: Route it in the shell**

Add `.storage` to `SidebarSection.isImplemented` and a `case .storage: StoragePage(store: store)` arm to `AppShell.detail`. Update `SidebarSectionTests`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd VitalsCore && swift test`
Expected: PASS — 6 new tests, non-zero count, no warnings.

- [ ] **Step 7: Capture the page**

Capture recipe from Task 1 Step 6, selecting **row 8**. Generate disk activity first so the chart is not flat — for example `find / -name "*.swift" > /dev/null 2>&1 &` before capturing. Confirm volume bars, a live throughput figure, and read/write bands. Report what you see.

- [ ] **Step 8: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests
git commit -m "feat: add Storage page with volume bars and read/write throughput"
```

---

### Task 7: Network page

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/NetworkPage.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`, `Shell/SidebarSection.swift`
- Test: `VitalsCore/Tests/VitalsUITests/NetworkPageTests.swift`

**Interfaces:**
- Consumes: `HardwarePage`, `MetricsStore.network`/`networkHistory`.
- Produces: `NetworkPage`; `NetworkPage.throughputSeries(history:) -> [ChartSeries]`; `NetworkPage.activeInterfaces(_:) -> [String]`.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/NetworkPageTests.swift`:

```swift
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Network page")
struct NetworkPageTests {

    private static func stamped(
        _ samples: [[String: NetworkThroughput]]
    ) -> [Timestamped<[String: NetworkThroughput]>] {
        samples.enumerated().map { Timestamped(timestamp: 1000 + TimeInterval($0.offset), sample: $0.element) }
    }

    @Test("splits into down and up bands, in megabytes per second")
    func splitsIntoDownAndUp() {
        let history = Self.stamped([
            ["en0": NetworkThroughput(bytesInPerSecond: 2_097_152, bytesOutPerSecond: 1_048_576)]
        ])
        let series = NetworkPage.throughputSeries(history: history)

        #expect(series.map(\.name) == ["Down", "Up"])
        #expect(series[0].values == [2.0])
        #expect(series[1].values == [1.0])
    }

    @Test("throughput is absolute, so a value below 1 is not read back as a percentage")
    func throughputUnitIsAbsolute() {
        let history = Self.stamped([
            ["en0": NetworkThroughput(bytesInPerSecond: 524_288, bytesOutPerSecond: 0)]
        ])
        #expect(NetworkPage.throughputSeries(history: history)[0].unit == .absolute(suffix: "MB/s"))
    }

    @Test("loopback is excluded, because local traffic is not network traffic")
    func loopbackIsExcluded() {
        let sample = [
            "lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000),
            "en0": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
        ]
        #expect(NetworkPage.throughputSeries(history: Self.stamped([sample]))[0].values == [1.0])
    }

    @Test("only interfaces carrying traffic are listed")
    func onlyActiveInterfacesListed() {
        let sample = [
            "en0": NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 0),
            "utun3": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0),
            "lo0": NetworkThroughput(bytesInPerSecond: 5000, bytesOutPerSecond: 5000),
        ]
        #expect(NetworkPage.activeInterfaces(sample) == ["en0"])
    }

    @Test("bands carry timestamps so gaps still break")
    func bandsCarryTimestamps() {
        let history = Self.stamped([
            ["en0": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)],
            ["en0": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)],
        ])
        #expect(NetworkPage.throughputSeries(history: history)[0].timestamps == [1000, 1001])
    }

    @Test("empty history yields no bands")
    func emptyHistoryYieldsNoBands() {
        #expect(NetworkPage.throughputSeries(history: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter NetworkPageTests`
Expected: FAIL — `cannot find 'NetworkPage' in scope`.

- [ ] **Step 3: Write the page**

Create `VitalsCore/Sources/VitalsUI/Pages/NetworkPage.swift`:

```swift
import SwiftUI
import SystemMetrics

public struct NetworkPage: View {
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    private static let bytesPerMegabyte = 1_048_576.0

    /// Loopback carries local traffic between processes on this machine. It is
    /// not network throughput, and including it would swamp the chart whenever
    /// anything talks to a local service.
    private static let excludedInterfaces: Set<String> = ["lo0"]

    /// Down and up throughput per spec §6.3, summed across every real
    /// interface and expressed in MB/s.
    public static func throughputSeries(
        history: [Timestamped<[String: NetworkThroughput]>]
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (NetworkThroughput) -> Double) -> ChartSeries {
            ChartSeries(
                name: name,
                values: history.map { entry in
                    entry.sample
                        .filter { !excludedInterfaces.contains($0.key) }
                        .values
                        .reduce(0) { $0 + value($1) } / bytesPerMegabyte
                },
                timestamps: timestamps,
                unit: .absolute(suffix: "MB/s")
            )
        }

        return [
            band("Down") { $0.bytesInPerSecond },
            band("Up") { $0.bytesOutPerSecond },
        ]
    }

    /// Interfaces currently carrying traffic, loopback excluded. An idle
    /// interface is omitted rather than listed at zero — a Mac has many.
    public static func activeInterfaces(_ throughput: [String: NetworkThroughput]) -> [String] {
        throughput
            .filter { !excludedInterfaces.contains($0.key) }
            .filter { $0.value.bytesInPerSecond > 0 || $0.value.bytesOutPerSecond > 0 }
            .keys
            .sorted()
    }

    // MARK: View

    private var current: [String: NetworkThroughput] { store.network ?? [:] }

    private var totalMBs: Double? {
        guard store.network != nil else { return nil }
        return current
            .filter { !Self.excludedInterfaces.contains($0.key) }
            .values
            .reduce(0) { $0 + $1.bytesInPerSecond + $1.bytesOutPerSecond } / Self.bytesPerMegabyte
    }

    public var body: some View {
        HardwarePage(
            title: "Network",
            vendorName: Self.activeInterfaces(current).first,
            showsAppleMark: false,
            primaryValue: totalMBs.map { String(format: "%.2f MB/s", $0) },
            series: Self.throughputSeries(history: store.networkHistory),
            stats: stats,
            disclosureKey: "NetworkPage.showFullSpecifications"
        ) {
            EmptyView()
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.network) }
    }

    private var stats: [HardwareStat] {
        let active = Self.activeInterfaces(current)
        return [
            HardwareStat(label: "Active interfaces", value: active.isEmpty ? nil : "\(active.count)"),
            HardwareStat(
                label: "Down",
                value: store.network.map { throughput in
                    String(
                        format: "%.2f MB/s",
                        throughput.filter { !Self.excludedInterfaces.contains($0.key) }
                            .values.reduce(0) { $0 + $1.bytesInPerSecond } / Self.bytesPerMegabyte
                    )
                }
            ),
            HardwareStat(
                label: "Up",
                value: store.network.map { throughput in
                    String(
                        format: "%.2f MB/s",
                        throughput.filter { !Self.excludedInterfaces.contains($0.key) }
                            .values.reduce(0) { $0 + $1.bytesOutPerSecond } / Self.bytesPerMegabyte
                    )
                }
            ),
            // Wi-Fi SSID and signal need CoreWLAN, whose SSID access requires
            // location authorisation — deferred with the menu bar work.
            HardwareStat(label: "Wi-Fi", value: nil),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        ForEach(Self.activeInterfaces(current), id: \.self) { name in
            StatRow(
                label: name,
                value: current[name].map {
                    String(
                        format: "%.2f down · %.2f up MB/s",
                        $0.bytesInPerSecond / Self.bytesPerMegabyte,
                        $0.bytesOutPerSecond / Self.bytesPerMegabyte
                    )
                }
            )
        }
        // Per-process network attribution for other users' processes needs the
        // privileged helper — milestone M3.
        StatRow(label: "Per-process traffic", value: nil)
    }
}
```

- [ ] **Step 4: Route it in the shell**

Add `.network` to `SidebarSection.isImplemented` and a `case .network: NetworkPage(store: store)` arm to `AppShell.detail`. Update `SidebarSectionTests` — this is the last page this plan adds, so the expected implemented set is `.overview, .cpu, .memory, .gpu, .storage, .network`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VitalsCore && swift test`
Expected: PASS — 6 new tests, non-zero count, no warnings.

- [ ] **Step 6: Capture the page**

Capture recipe from Task 1 Step 6, selecting **row 9**. Generate traffic first, e.g. `curl -s https://www.apple.com > /dev/null &`. Confirm down/up bands and a live throughput figure. Report what you see.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests
git commit -m "feat: add Network page with down/up throughput"
```

---

### Task 8: Cross-page consistency pass

Five pages built one at a time drift. This task looks at them together, which is the only way some defects are visible.

**Files:**
- Modify: whichever page files the checks below turn up
- Test: `VitalsCore/Tests/VitalsUITests/PageConsistencyTests.swift`

**Interfaces:**
- Consumes: all five pages.
- Produces: no new API — this task tightens what exists.

- [ ] **Step 1: Write the consistency test**

Create `VitalsCore/Tests/VitalsUITests/PageConsistencyTests.swift`:

```swift
import Testing
@testable import VitalsUI

@Suite("Page consistency")
struct PageConsistencyTests {

    @Test("every implemented section has a route, and every route is marked implemented")
    func implementedSectionsMatchRoutes() {
        // A section marked implemented but not routed shows the "not built"
        // placeholder; a section routed but not marked is unreachable. Both
        // are silent failures without this check.
        let implemented = SidebarSection.allCases.filter(\.isImplemented)
        #expect(Set(implemented) == Set([.overview, .cpu, .memory, .gpu, .storage, .network]))
    }

    @Test("each page uses a distinct disclosure key")
    func disclosureKeysAreDistinct() {
        // A shared key would make expanding one page's specifications expand
        // every other page's too.
        let keys = [
            "CPUPage.showFullSpecifications",
            "MemoryPage.showFullSpecifications",
            "GPUPage.showFullSpecifications",
            "StoragePage.showFullSpecifications",
            "NetworkPage.showFullSpecifications",
        ]
        #expect(Set(keys).count == keys.count)
    }

    @Test("absence is worded consistently across components")
    func absenceWordingIsConsistent() {
        // Large readouts use an em dash, label/value rows use "Unavailable".
        // Two words for one idea would read as two different states.
        #expect(MetricTile.displayValue(nil) == "—")
        #expect(StatRow.displayValue(nil) == "Unavailable")
    }
}
```

- [ ] **Step 2: Run test to verify it passes or reveals a gap**

Run: `cd VitalsCore && swift test --filter PageConsistencyTests`
Expected: PASS. If `implementedSectionsMatchRoutes` fails, a page was routed without being marked implemented or vice versa — fix the section, not the test.

- [ ] **Step 3: Capture all five pages side by side**

Capture each page using the recipe from Task 1 Step 6, at rows 5 through 9, into `/tmp/vitals-render/page-{cpu,memory,gpu,storage,network}.png`. Read all five.

Check specifically, and report each:
- Do all five headers sit at the same height with the same badge treatment?
- Do all five primary values use the same type size and colour?
- Are the four key stats aligned identically across pages?
- Does every page's disclosure collapse and expand independently?
- Does any page show a `0` or a blank where it should show "Unavailable" or an em dash?

Fix anything inconsistent in the page that differs, not in `HardwarePage` — unless the divergence is the container's fault, in which case fix it once there.

- [ ] **Step 4: Run the full suite**

Run: `cd VitalsCore && swift test`
Expected: PASS, non-zero count, no warnings.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore
git commit -m "test: add cross-page consistency checks"
```

---

## Completion criteria

- `cd VitalsCore && swift test` passes with no failures and no warnings.
- Selecting Memory, GPU, Storage, or Network in the sidebar shows a live page, not the "Not built yet" placeholder.
- Every page's chart carries timestamps, so leaving and returning breaks the line rather than splicing.
- Memory shows spec bandwidth labelled as a specification and **no fabricated MHz** on Apple Silicon.
- GPU omits an engine band the driver does not report, rather than drawing it flat at zero.
- Storage shows both volume capacity bars and read/write throughput — `ioCounters()` is no longer dead code.
- Network excludes loopback from its totals.
- No page renders `0` or a blank where a value is unmeasurable.

## What comes next

**M1-B-3** builds the Processes pane: a sortable, searchable, heat-mapped table with a context menu and an inspector sheet. It is the last piece of M1 and the only remaining Windows Task Manager surface in this milestone. The Sensors page waits on the IOHID spike; Startup, Services, Users, and History are M4.
