# Vitals UI Foundation Implementation Plan (M1-B-1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Vitals design system, the typed metrics store that bridges the engine to SwiftUI, the app shell with glass sidebar navigation, the Overview tile grid, and the complete CPU page — establishing every pattern the remaining hardware pages inherit.

**Architecture:** Two new targets in the existing `VitalsCore` package. `VitalsUI` holds the design system: pure geometry and colour math that carries the test coverage, plus thin SwiftUI views over it. `VitalsApp` is a SwiftUI executable. The bridge between them is `MetricsStore` — an `@Observable @MainActor` class that subscribes to the engine's `AsyncStream`s, performs the `MetricValue.value as? T` cast exactly once, and publishes typed state. Views drive subscription lifetime through `.task {}`, so SwiftUI's own view lifecycle becomes the engine's attach/detach signal.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, `ImageRenderer` for headless visual verification. No third-party dependencies.

## Global Constraints

- **Platform floor:** macOS 26.0, already declared as `.macOS("26.0")` in `VitalsCore/Package.swift`.
- **Swift language mode 6** on every target, strict concurrency.
- **No third-party dependencies.** Foundation, SwiftUI, Observation, Darwin, IOKit, Metal, Swift Testing only.
- **Never fabricate a number.** An unmeasurable value renders as an em dash or the word "unavailable" — never `0`, `0%`, `--`, or a blank that reads as zero. Most `SystemMetrics` types are Optional precisely for this; the UI is the layer where that discipline either holds or is lost.
- **Subscription-driven.** A page must subscribe only to the series it displays, and must release them when it disappears. Never subscribe to a series "just in case".
- **Build and test output must be pristine** — no warnings.
- **Package root:** `VitalsCore/`. All paths are relative to `/Users/george/Developer/Vitals`.
- **Test command:** `cd VitalsCore && swift test`.
- **`swift test --filter` matches type identifiers, not `@Suite` display names.** `--filter ChartGeometryTests` works; `--filter "Chart geometry"` matches zero tests and still reports success. A run reporting "Test run with 0 tests ... passed" is a failure to run.
- **`String(cString:)` is deprecated** in Swift 6; use the existing `String(cCharBuffer:)` helper in `Sources/SystemMetrics/Support/`.

## Consumed API from M1-A (verified against the built package)

These are the exact signatures this plan builds on. They are not guesses — they were extracted from the merged `VitalsCore` source.

```swift
// MetricsEngine
public actor MetricsEngine {
    public init(intervalOverride: Duration? = nil, historyCapacity: Int = 600)
    public func register(_ sampler: AnySampler, for key: SeriesKey, cadence: SamplingCadence)
    public func subscribe(to key: SeriesKey) -> AsyncStream<MetricValue>
    public func history(for key: SeriesKey) -> [MetricValue]
    public var activeSeries: Set<SeriesKey> { get }
}
public enum SeriesKey: String, Sendable, Hashable, CaseIterable {
    case cpu, memory, gpu, storage, network, processes
}
public struct MetricValue: @unchecked Sendable {
    public let timestamp: TimeInterval
    public let value: Any            // <- the cast this plan centralises
}
public enum StandardSamplers {
    public static func registerAll(on engine: MetricsEngine) async
}

// SystemMetrics — payload types per series
// .cpu      -> CPULoadSample     (cores: [CoreLoad], total: Double, clusterLoads(for:))
// .memory   -> MemorySample      (app/wired/compressed/cached/free: UInt64, used: UInt64,
//                                 swapUsed/swapTotal: UInt64?, pressure: MemoryPressure?)
// .gpu      -> [GPUSample]       (deviceUtilisation/rendererUtilisation/tilerUtilisation: Double?,
//                                 inUseMemoryBytes/allocatedMemoryBytes: UInt64?)
// .storage  -> [Volume]          (name, totalBytes, availableBytes, isInternal, usedFraction)
// .network  -> [String: NetworkThroughput]  (bytesInPerSecond, bytesOutPerSecond)
// .processes-> ProcessSeriesSample (processes: [ProcessSnapshot], cpuUsage: [pid_t: Double])

public struct CoreLoad: Sendable, Equatable {
    public let user, system, idle, nice: Double
    public var busy: Double            // user + system + nice, 0...1
}
public struct CPUTopology: Sendable, Equatable {
    public let brand: String
    public let physicalCores: Int?     // Optional — absent sysctl reads nil, never 0
    public let logicalCores: Int?
    public let clusters: [CPUCluster]  // CPUCluster(name, coreCount, logicalCoreCount)
    public let l1DataCacheBytes, l2CacheBytes, l3CacheBytes: Int?  // L3 is nil on Apple Silicon
    public var isAppleSilicon: Bool
    public var frequencyAvailable: Bool  // false until IOReport lands
}
public struct HardwareProfile: Sendable {
    public let cpu: CPUTopology
    public let memory: MemoryHardware
    public let gpus: [GPUDevice]
    public let sensorsAvailable: MetricAvailability   // .unavailable(reason:) today
    public let frequencyAvailable: MetricAvailability // .unavailable(reason:) today
    public static func detect(sysctl:sensors:) throws -> HardwareProfile
}
public struct SystemLoad: Sendable, Equatable {
    public let uptimeSeconds: TimeInterval
    public let loadAverage1, loadAverage5, loadAverage15: Double?
    public static func current() -> SystemLoad
}
```

## Out of scope for this plan

- **The remaining hardware pages** — Memory, GPU, Storage, Network, Sensors. They inherit the CPU page's template wholesale; building one page well is what this plan is for. They are M1-B-2.
- **The Processes pane.** A sortable, searchable, heat-mapped table with a context menu and an inspector sheet is its own plan. That is M1-B-3.
- **Desktop widgets and the menu bar.** Milestone M2.
- **A bundled `.app`.** `VitalsApp` is a SwiftPM executable target run with `swift run VitalsApp`. This is deliberate: it is fully automatable from the command line, and nothing in this plan needs bundle identity. The menu bar item and widgets in M2 *do* need it (`LSUIElement`, an activation policy, an icon), so the Xcode project arrives with M2 — driven by a real requirement rather than ceremony.
- **Sensor and CPU-frequency display.** `HardwareProfile` reports both as `.unavailable(reason:)`. The CPU page renders that reason; it does not show a fabricated temperature or clock.

---

### Task 1: App and UI targets, and the typed metrics store

The store is built first because every view depends on it, and because its casting and history logic is pure enough to test properly — unlike the views over it.

**Files:**
- Modify: `VitalsCore/Package.swift`
- Create: `VitalsCore/Sources/VitalsUI/MetricsStore.swift`
- Create: `VitalsCore/Sources/VitalsApp/VitalsApp.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `MetricsEngine`, `SeriesKey`, `MetricValue`, `StandardSamplers`, `CPULoadSample`, `MemorySample`, `HardwareProfile` from M1-A.
- Produces: `MetricsStore` (`@Observable @MainActor final class`) with `init(engine:profile:historyLimit:)`, `func stream(_ key: SeriesKey) async`, and read-only `cpu`, `cpuHistory`, `memory`, `memoryHistory`, `systemLoad`, `profile`. Every later task uses it.

- [ ] **Step 1: Add the two targets to the package manifest**

Replace the `products:` and `targets:` arrays in `VitalsCore/Package.swift` with these. The existing four targets are unchanged; two library/executable targets and one test target are added.

```swift
    products: [
        .library(name: "SystemMetrics", targets: ["SystemMetrics"]),
        .library(name: "MetricsEngine", targets: ["MetricsEngine"]),
        .library(name: "VitalsUI", targets: ["VitalsUI"]),
        .executable(name: "vitals-dump", targets: ["vitals-dump"]),
        .executable(name: "VitalsApp", targets: ["VitalsApp"]),
    ],
    targets: [
        .target(
            name: "SystemMetrics",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MetricsEngine",
            dependencies: ["SystemMetrics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VitalsUI",
            dependencies: ["SystemMetrics", "MetricsEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "vitals-dump",
            dependencies: ["SystemMetrics", "MetricsEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "VitalsApp",
            dependencies: ["VitalsUI", "SystemMetrics", "MetricsEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SystemMetricsTests",
            dependencies: ["SystemMetrics"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MetricsEngineTests",
            dependencies: ["MetricsEngine"]
        ),
        .testTarget(
            name: "VitalsUITests",
            dependencies: ["VitalsUI"]
        ),
    ]
```

- [ ] **Step 2: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`:

```swift
import Foundation
import MetricsEngine
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("MetricsStore")
struct MetricsStoreTests {

    /// An engine preloaded with one controllable sampler, so store behaviour is
    /// testable without touching real hardware.
    private func engineYielding(_ values: [CPULoadSample]) async -> MetricsEngine {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let box = ValueBox(values)
        await engine.register(
            AnySampler { try box.next() },
            for: .cpu,
            cadence: .fast
        )
        return engine
    }

    private static func load(_ busy: Double) -> CPULoadSample {
        CPULoadSample(cores: [CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0)])
    }

    @Test("starts with no value, because nothing has been sampled yet")
    func startsEmpty() async throws {
        let engine = await engineYielding([])
        let store = MetricsStore(engine: engine, profile: nil)
        #expect(store.cpu == nil)
        #expect(store.cpuHistory.isEmpty)
    }

    @Test("publishes typed CPU values from the untyped stream")
    func publishesTypedValues() async throws {
        let engine = await engineYielding([Self.load(0.25), Self.load(0.5)])
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.count >= 2 }
        task.cancel()

        #expect(store.cpu?.total == 0.5)
        #expect(store.cpuHistory.count >= 2)
    }

    @Test("history is capped so a long-running app cannot grow without bound")
    func historyIsCapped() async throws {
        let engine = await engineYielding(Array(repeating: Self.load(0.1), count: 100))
        let store = MetricsStore(engine: engine, profile: nil, historyLimit: 5)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.count == 5 }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.cpuHistory.count == 5)
    }

    @Test("a payload of the wrong type is ignored rather than crashing")
    func wrongTypeIsIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a CPU sample" }, for: .cpu, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.cpu == nil)
        #expect(store.cpuHistory.isEmpty)
    }

    @Test("cancelling the streaming task releases the engine subscription")
    func cancellationReleasesSubscription() async throws {
        let engine = await engineYielding(Array(repeating: Self.load(0.1), count: 100))
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.isEmpty == false }
        #expect(await engine.activeSeries.contains(.cpu))

        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.cpu) == false }
    }
}

/// Vends prerecorded samples, then throws so the series goes quiet.
final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [CPULoadSample]
    private let last: CPULoadSample?

    init(_ values: [CPULoadSample]) {
        remaining = values
        last = values.last
    }

    enum Empty: Error { case exhausted }

    func next() throws -> CPULoadSample {
        try lock.withLock {
            if remaining.isEmpty {
                guard let last else { throw Empty.exhausted }
                return last
            }
            return remaining.removeFirst()
        }
    }
}

/// Polls a main-actor condition with a bounded timeout, so a regression fails
/// rather than hanging.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition not met within \(timeout)")
}

func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition not met within \(timeout)")
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: FAIL — `no such module 'VitalsUI'`.

- [ ] **Step 4: Write the store**

Create `VitalsCore/Sources/VitalsUI/MetricsStore.swift`:

```swift
import Foundation
import MetricsEngine
import Observation
import SystemMetrics

/// Bridges `MetricsEngine` to SwiftUI.
///
/// The engine publishes `MetricValue`, whose payload is `Any`. Casting that to a
/// concrete sample type happens here, once, rather than in every view. Views
/// observe typed properties and never see the erasure.
///
/// Subscription lifetime is driven by SwiftUI: a page calls `stream(_:)` from
/// `.task {}`, which SwiftUI cancels when the view disappears. That cancellation
/// terminates the engine's `AsyncStream`, which detaches the subscriber, which
/// stops sampling. The engine's subscription-driven design and SwiftUI's view
/// lifecycle line up exactly, so no manual bookkeeping is needed.
@Observable
@MainActor
public final class MetricsStore {

    public private(set) var cpu: CPULoadSample?
    public private(set) var cpuHistory: [CPULoadSample] = []

    public private(set) var memory: MemorySample?
    public private(set) var memoryHistory: [MemorySample] = []

    /// Uptime and load average. Cheap and slow-moving, so it is read on demand
    /// rather than sampled on a schedule.
    public var systemLoad: SystemLoad { SystemLoad.current() }

    /// Static hardware description. `nil` only in tests; the app always has one.
    public let profile: HardwareProfile?

    private let engine: MetricsEngine
    private let historyLimit: Int

    public init(engine: MetricsEngine, profile: HardwareProfile?, historyLimit: Int = 600) {
        self.engine = engine
        self.profile = profile
        self.historyLimit = historyLimit
    }

    /// Subscribes to a series and republishes it as typed state until cancelled.
    ///
    /// Call from `.task {}`. Returns when the task is cancelled or the stream
    /// finishes.
    public func stream(_ key: SeriesKey) async {
        for await value in await engine.subscribe(to: key) {
            apply(value, for: key)
        }
    }

    private func apply(_ value: MetricValue, for key: SeriesKey) {
        // A payload of an unexpected type is dropped rather than crashing or
        // substituted with a zero — an unreadable series shows as absent.
        switch key {
        case .cpu:
            guard let sample = value.value as? CPULoadSample else { return }
            cpu = sample
            append(sample, to: &cpuHistory)
        case .memory:
            guard let sample = value.value as? MemorySample else { return }
            memory = sample
            append(sample, to: &memoryHistory)
        case .gpu, .storage, .network, .processes:
            // Handled by later plans. Ignored rather than crashed on, so a page
            // that subscribes early does not fault.
            return
        }
    }

    private func append<Sample>(_ sample: Sample, to history: inout [Sample]) {
        history.append(sample)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
```

- [ ] **Step 5: Write the app entry point**

Create `VitalsCore/Sources/VitalsApp/VitalsApp.swift`. This is a stub window for now; Task 7 replaces its body with the real shell.

```swift
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

@main
struct VitalsApp: App {
    @State private var store: MetricsStore?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup("Vitals") {
            Group {
                if let store {
                    Text("CPU: \(store.cpu.map { "\(Int($0.total * 100))%" } ?? "—")")
                        .task { await store.stream(.cpu) }
                } else if let startupError {
                    Text(startupError)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .task { await start() }
        }
        .windowStyle(.hiddenTitleBar)
    }

    private func start() async {
        guard store == nil, startupError == nil else { return }
        do {
            let profile = try HardwareProfile.detect()
            let engine = MetricsEngine()
            await StandardSamplers.registerAll(on: engine)
            store = MetricsStore(engine: engine, profile: profile)
        } catch {
            // Surfaced rather than swallowed: if the machine cannot describe its
            // own hardware, saying so beats an empty window.
            startupError = "Could not read this machine's hardware: \(error)"
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: PASS — 5 tests passing, non-zero count.

- [ ] **Step 7: Verify the app launches**

Run: `cd VitalsCore && swift run VitalsApp`

A window opens showing a live CPU percentage that changes. Quit with ⌘Q. Confirm the number is not stuck and not `—`. Then confirm the subscription released:

Run: `cd VitalsCore && swift build 2>&1 | grep -i warning || echo "no warnings"`

- [ ] **Step 8: Commit**

```bash
git add VitalsCore/Package.swift VitalsCore/Sources/VitalsUI VitalsCore/Sources/VitalsApp VitalsCore/Tests/VitalsUITests
git commit -m "feat: add VitalsUI and VitalsApp targets with typed metrics store"
```

---

### Task 2: Design tokens

Colours, typography, spacing, and radii as pure values. Kept separate from any view so they are testable and so a single edit restyles the whole app.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Design/Tokens.swift`
- Test: `VitalsCore/Tests/VitalsUITests/TokensTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Vitals.Palette` with `cpu`, `memory`, `gpu`, `storage`, `network`, `warning` as `Color`; `Vitals.Metrics` with `cornerRadius`, `tileSpacing`, `contentPadding`, `chartHeight` as `CGFloat`; `Vitals.Typography` with `readout`, `tileValue`, `label`, `sectionTitle` as `Font`; `Vitals.seriesColors(count:)` returning a stable palette slice. Every view uses these.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/TokensTests.swift`:

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@Suite("Design tokens")
struct TokensTests {

    @Test("series colours are stable for a given index")
    func seriesColoursAreStable() {
        #expect(Vitals.seriesColors(count: 4) == Vitals.seriesColors(count: 4))
    }

    @Test("series colours never repeat within one chart")
    func seriesColoursAreDistinct() {
        // Four is the widest decomposition the spec calls for — the Memory page's
        // wired / active / compressed / cached breakdown.
        let colors = Vitals.seriesColors(count: 4)
        #expect(colors.count == 4)
        #expect(Set(colors.map(String.init(describing:))).count == 4)
    }

    @Test("asking for more series than the palette holds still returns that many")
    func paletteWrapsRatherThanTruncating() {
        #expect(Vitals.seriesColors(count: 9).count == 9)
    }

    @Test("asking for no series returns nothing")
    func zeroSeriesIsEmpty() {
        #expect(Vitals.seriesColors(count: 0).isEmpty)
    }

    @Test("layout metrics are positive and ordered sensibly")
    func layoutMetricsAreSane() {
        #expect(Vitals.Metrics.cornerRadius > 0)
        #expect(Vitals.Metrics.tileSpacing > 0)
        #expect(Vitals.Metrics.contentPadding >= Vitals.Metrics.tileSpacing)
        #expect(Vitals.Metrics.chartHeight > Vitals.Metrics.contentPadding)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter TokensTests`
Expected: FAIL — `cannot find 'Vitals' in scope`.

- [ ] **Step 3: Write the tokens**

Create `VitalsCore/Sources/VitalsUI/Design/Tokens.swift`:

```swift
import SwiftUI

/// Design tokens. One edit here restyles the whole app, which is the point of
/// keeping them out of the views.
public enum Vitals {

    /// Per-subsystem accent colours. Each hardware page owns one hue so a glance
    /// at a chart identifies its subject without reading the label.
    public enum Palette {
        public static let cpu = Color(red: 0.49, green: 0.78, blue: 1.00)
        public static let memory = Color(red: 0.70, green: 0.61, blue: 1.00)
        public static let gpu = Color(red: 1.00, green: 0.70, blue: 0.49)
        public static let storage = Color(red: 0.56, green: 0.88, blue: 0.75)
        public static let network = Color(red: 0.98, green: 0.80, blue: 0.45)
        public static let warning = Color(red: 1.00, green: 0.47, blue: 0.47)
    }

    public enum Metrics {
        /// Matches Apple's widget corner radius so a Vitals surface sits
        /// naturally beside a first-party one.
        public static let cornerRadius: CGFloat = 16
        public static let tileSpacing: CGFloat = 12
        public static let contentPadding: CGFloat = 20
        public static let chartHeight: CGFloat = 132
    }

    public enum Typography {
        /// Large numeric readouts. Monospaced digits so a changing value does not
        /// jitter its own layout — the single most important typographic choice
        /// in a live monitor.
        public static let readout = Font.system(size: 40, weight: .semibold, design: .rounded)
            .monospacedDigit()
        public static let tileValue = Font.system(size: 22, weight: .semibold)
            .monospacedDigit()
        public static let label = Font.system(size: 11, weight: .medium)
        public static let sectionTitle = Font.system(size: 13, weight: .semibold)
    }

    /// A stable colour per series index, for stacked charts.
    ///
    /// Ordering is fixed so a chart's colours do not shuffle between renders.
    /// The ramp wraps rather than truncating, so a caller asking for more series
    /// than there are hues still gets one colour per series.
    public static func seriesColors(count: Int) -> [Color] {
        guard count > 0 else { return [] }
        let ramp: [Color] = [
            Palette.cpu,
            Palette.storage,
            Palette.memory,
            Palette.gpu,
            Palette.network,
            Palette.warning,
        ]
        return (0..<count).map { ramp[$0 % ramp.count] }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter TokensTests`
Expected: PASS — 5 tests passing.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Design VitalsCore/Tests/VitalsUITests/TokensTests.swift
git commit -m "feat: add Vitals design tokens"
```

---

### Task 3: Chart geometry

The maths behind both chart modes: stacking, normalisation, point mapping, and Catmull-Rom smoothing. All pure, so it carries the chart's test coverage and the SwiftUI layer over it stays thin enough to trust by inspection.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Charts/ChartGeometry.swift`
- Test: `VitalsCore/Tests/VitalsUITests/ChartGeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ChartSeries` (`name: String`, `values: [Double]`); `ChartGeometry.stack(_:) -> [[Double]]`; `ChartGeometry.points(_:in:upperBound:) -> [CGPoint]`; `ChartGeometry.smoothPath(through:) -> Path`; `ChartGeometry.upperBound(for:) -> Double`. Tasks 4, 5, and 6 use all of them.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/ChartGeometryTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import VitalsUI

@Suite("Chart geometry")
struct ChartGeometryTests {

    // MARK: Stacking

    @Test("a single series stacks to itself")
    func singleSeriesStacksToItself() {
        let stacked = ChartGeometry.stack([ChartSeries(name: "a", values: [0.2, 0.4])])
        #expect(stacked == [[0.2, 0.4]])
    }

    @Test("stacked series accumulate so bands sit on top of one another")
    func seriesAccumulate() {
        let stacked = ChartGeometry.stack([
            ChartSeries(name: "p", values: [0.2, 0.3]),
            ChartSeries(name: "e", values: [0.1, 0.1]),
        ])
        // Compared with a tolerance: 0.2 + 0.1 is not exactly 0.3 in IEEE-754,
        // so an exact array comparison could never hold. The tolerance is ~1e-7
        // of the error's magnitude but orders of magnitude below what a real
        // stacking bug would produce, so it still discriminates.
        #expect(approximatelyEqual(stacked, [[0.2, 0.3], [0.3, 0.4]]))
    }

    @Test("series of differing lengths stack over their common prefix")
    func raggedSeriesUseCommonPrefix() {
        let stacked = ChartGeometry.stack([
            ChartSeries(name: "p", values: [0.2, 0.3, 0.4]),
            ChartSeries(name: "e", values: [0.1, 0.1]),
        ])
        #expect(approximatelyEqual(stacked, [[0.2, 0.3], [0.3, 0.4]]))
    }

    /// Element-wise comparison with a tolerance, for values that are summed
    /// before being compared.
    private func approximatelyEqual(
        _ lhs: [[Double]],
        _ rhs: [[Double]],
        tolerance: Double = 1e-9
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.count == right.count
                && zip(left, right).allSatisfy { abs($0 - $1) < tolerance }
        }
    }

    @Test("stacking nothing yields nothing")
    func emptyInputStacksToNothing() {
        #expect(ChartGeometry.stack([]).isEmpty)
    }

    // MARK: Upper bound

    @Test("a fractional series is bounded at 1 so 40% does not fill the chart")
    func fractionalSeriesBoundedAtOne() {
        #expect(ChartGeometry.upperBound(for: [[0.1, 0.4]]) == 1.0)
    }

    @Test("a series exceeding 1 grows the bound to its peak")
    func unboundedSeriesUsesPeak() {
        // Throughput and per-process CPU are not fractions — a process on four
        // cores legitimately reads 4.0.
        #expect(ChartGeometry.upperBound(for: [[0.5, 3.2]]) == 3.2)
    }

    @Test("an all-zero series still has a positive bound, so nothing divides by zero")
    func zeroSeriesHasPositiveBound() {
        #expect(ChartGeometry.upperBound(for: [[0, 0, 0]]) == 1.0)
    }

    // MARK: Point mapping

    @Test("values map across the full width with y inverted for screen space")
    func valuesMapToRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([0, 0.5, 1.0], in: rect, upperBound: 1.0)

        #expect(points.count == 3)
        #expect(points[0] == CGPoint(x: 0, y: 50))    // zero sits on the baseline
        #expect(points[1] == CGPoint(x: 50, y: 25))
        #expect(points[2] == CGPoint(x: 100, y: 0))   // full value reaches the top
    }

    @Test("a single value is placed at the trailing edge, where 'now' lives")
    func singleValueSitsAtTrailingEdge() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([0.5], in: rect, upperBound: 1.0)
        #expect(points == [CGPoint(x: 100, y: 25)])
    }

    @Test("no values map to no points")
    func emptyValuesMapToNoPoints() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(ChartGeometry.points([], in: rect, upperBound: 1.0).isEmpty)
    }

    @Test("values above the bound are clamped inside the rect")
    func valuesAboveBoundAreClamped() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([2.0], in: rect, upperBound: 1.0)
        #expect(points[0].y == 0)
    }

    // MARK: Smoothing

    @Test("no points make no path")
    func smoothPathIsEmptyForNoPoints() {
        #expect(ChartGeometry.smoothPath(through: []).isEmpty)
    }

    @Test("a smoothed path of one point is empty — a point is not a line")
    func smoothPathNeedsTwoPoints() {
        #expect(ChartGeometry.smoothPath(through: [CGPoint(x: 0, y: 0)]).isEmpty)
    }

    @Test("a smoothed path spans from the first point to the last")
    func smoothPathSpansInput() {
        let points = [
            CGPoint(x: 0, y: 40), CGPoint(x: 25, y: 10),
            CGPoint(x: 50, y: 30), CGPoint(x: 75, y: 5),
        ]
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect
        #expect(bounds.minX == 0)
        #expect(bounds.maxX == 75)
    }

    @Test("smoothing does not overshoot the input's vertical range excessively")
    func smoothPathDoesNotOvershootWildly() {
        // Catmull-Rom can overshoot on sharp spikes. A monitor's chart must not
        // draw a curve implying a value the machine never reported, so the
        // overshoot is bounded.
        let points = [
            CGPoint(x: 0, y: 50), CGPoint(x: 25, y: 50),
            CGPoint(x: 50, y: 0), CGPoint(x: 75, y: 50),
        ]
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect

        // The bound is deliberately loose enough to be independent of whether
        // `boundingRect` includes control points: at tension 0.25 the highest
        // control point is y=62.5, while classic tension 0.5 would put it at
        // y=75. So this still fails if the smoothing is retuned to overshoot,
        // which is the regression it exists to catch.
        #expect(bounds.minY >= -15)
        #expect(bounds.maxY <= 65)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter ChartGeometryTests`
Expected: FAIL — `cannot find 'ChartGeometry' in scope`.

- [ ] **Step 3: Write the geometry**

Create `VitalsCore/Sources/VitalsUI/Charts/ChartGeometry.swift`:

```swift
import CoreGraphics
import SwiftUI

/// One named line or band on a chart. Values are oldest-first.
public struct ChartSeries: Sendable, Equatable {
    public let name: String
    public let values: [Double]

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }
}

/// The maths behind both chart modes. Pure, and therefore the part that carries
/// the chart's test coverage — the SwiftUI layer over it is deliberately thin.
public enum ChartGeometry {

    /// Converts series into cumulative bands, so each sits on top of the last.
    ///
    /// Series of differing lengths are truncated to their common prefix rather
    /// than padded: padding a short series with zeroes would draw a band
    /// claiming a measurement that was never taken.
    public static func stack(_ series: [ChartSeries]) -> [[Double]] {
        guard let shortest = series.map(\.values.count).min(), shortest > 0 else { return [] }

        var running = [Double](repeating: 0, count: shortest)
        return series.map { entry in
            for index in 0..<shortest {
                running[index] += entry.values[index]
            }
            return running
        }
    }

    /// The value the top of the chart represents.
    ///
    /// Fractional metrics (CPU busy, GPU utilisation) are bounded at 1 so a 40%
    /// reading does not fill the frame. Unbounded metrics (throughput,
    /// multi-core process CPU) grow to their own peak.
    public static func upperBound(for stacked: [[Double]]) -> Double {
        let peak = stacked.flatMap { $0 }.max() ?? 0
        return max(peak, 1.0)
    }

    /// Maps values onto a rect, oldest at the leading edge, newest at the
    /// trailing edge. Y is inverted for screen space, and clamped so an
    /// out-of-range value cannot draw outside the chart.
    public static func points(
        _ values: [Double],
        in rect: CGRect,
        upperBound: Double
    ) -> [CGPoint] {
        guard !values.isEmpty, upperBound > 0 else { return [] }

        // A lone value belongs at the trailing edge: it is "now", not "the whole
        // history".
        guard values.count > 1 else {
            let clamped = min(max(values[0] / upperBound, 0), 1)
            return [CGPoint(x: rect.maxX, y: rect.maxY - clamped * rect.height)]
        }

        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let clamped = min(max(value / upperBound, 0), 1)
            return CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - clamped * rect.height
            )
        }
    }

    /// A Catmull-Rom smoothed path through the given points.
    ///
    /// Tangents are scaled by `tension` below the classic 0.5 so the curve stays
    /// close to its data. A monitoring chart that overshoots is drawing a value
    /// the machine never reported.
    public static func smoothPath(through points: [CGPoint]) -> Path {
        guard points.count > 1 else { return Path() }

        let tension: CGFloat = 0.25
        var path = Path()
        path.move(to: points[0])

        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]

            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension,
                y: p1.y + (p2.y - p0.y) * tension
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension,
                y: p2.y - (p3.y - p1.y) * tension
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter ChartGeometryTests`
Expected: PASS — 15 tests passing.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Charts VitalsCore/Tests/VitalsUITests/ChartGeometryTests.swift
git commit -m "feat: add chart geometry with bounded Catmull-Rom smoothing"
```

---

### Task 4: Glass surface and the visual verification harness

Establishes the Liquid Glass surface every panel and tile sits on, and the `ImageRenderer` harness later tasks use to verify rendering without a screen-recording permission.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Design/GlassSurface.swift`
- Create: `VitalsCore/Tests/VitalsUITests/RenderHarness.swift`
- Test: `VitalsCore/Tests/VitalsUITests/GlassSurfaceTests.swift`

**Interfaces:**
- Consumes: `Vitals.Metrics` from Task 2.
- Produces: `View.glassSurface(cornerRadius:)` modifier; `GlassPanel<Content>` view; and in tests, `renderPNG(_:size:named:) -> URL` writing to `/tmp/vitals-render/`. Tasks 5, 6, 8, and 9 use the harness.

**On Liquid Glass:** macOS 26 provides `.glassEffect(_:in:)` and `GlassEffectContainer` natively. If the exact signature differs from what is written here, **report the compiler's message and the corrected signature** rather than substituting a hand-rolled `.ultraThinMaterial` blur — the whole point of targeting 26 is getting the real material.

- [ ] **Step 1: Write the render harness**

Create `VitalsCore/Tests/VitalsUITests/RenderHarness.swift`:

```swift
import AppKit
import SwiftUI
import Testing

/// Renders a SwiftUI view to a PNG offscreen.
///
/// This exists because verifying a macOS app's appearance normally needs a
/// screen-recording permission that a non-interactive session does not have.
/// `ImageRenderer` needs no permission and no window.
///
/// Caveat worth knowing: `.glassEffect` samples what is *behind* a view, and
/// offscreen there is nothing behind it. These renders verify layout,
/// typography, and chart geometry — not the glass material itself, which must
/// be judged in the running app.
@MainActor
func renderPNG(
    _ view: some View,
    size: CGSize,
    named name: String
) throws -> URL {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 2

    let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))

    let directory = URL(fileURLWithPath: "/tmp/vitals-render")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(name).png")
    try png.write(to: url)

    // A render that produced a uniformly blank image drew nothing. Asserting
    // only that the file exists would pass for a chart that silently failed to
    // paint, which is exactly the bug these tests exist to catch.
    try #require(isNotBlank(bitmap), "\(name) rendered a uniformly blank image")

    return url
}

/// True when the bitmap contains more than one distinct pixel value.
///
/// Deliberately weak: it cannot judge whether a render looks *right*, only that
/// something was drawn. Appearance is judged by opening the PNG.
private func isNotBlank(_ bitmap: NSBitmapImageRep) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }

    let first = bitmap.colorAt(x: 0, y: 0)
    let stepX = max(bitmap.pixelsWide / 16, 1)
    let stepY = max(bitmap.pixelsHigh / 16, 1)

    for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            if bitmap.colorAt(x: x, y: y) != first { return true }
        }
    }
    return false
}
```

**Note on the blank check:** it samples a 16×16 grid rather than every pixel, so it is fast enough to run on every render. It proves something was drawn, not that the drawing is correct — that judgement comes from opening the PNG, which each task's verification step asks you to do.

- [ ] **Step 2: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/GlassSurfaceTests.swift`:

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Glass surface")
struct GlassSurfaceTests {

    @Test("a glass panel renders at the requested size")
    func panelRenders() throws {
        let panel = GlassPanel {
            VStack(alignment: .leading) {
                Text("PROCESSOR").font(Vitals.Typography.label)
                Text("18%").font(Vitals.Typography.readout)
            }
        }
        let url = try renderPNG(panel, size: CGSize(width: 240, height: 140), named: "glass-panel")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the surface modifier composes onto an arbitrary view")
    func modifierComposes() throws {
        let view = Text("42").padding().glassSurface()
        let url = try renderPNG(view, size: CGSize(width: 120, height: 80), named: "glass-modifier")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter GlassSurfaceTests`
Expected: FAIL — `cannot find 'GlassPanel' in scope`.

- [ ] **Step 4: Write the glass surface**

Create `VitalsCore/Sources/VitalsUI/Design/GlassSurface.swift`:

```swift
import SwiftUI

extension View {
    /// The house surface: Liquid Glass in a rounded rectangle.
    ///
    /// Every panel, tile, and widget in Vitals sits on this, so the app reads as
    /// one material rather than an assortment of boxes.
    public func glassSurface(cornerRadius: CGFloat = Vitals.Metrics.cornerRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// A padded glass container.
public struct GlassPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(
        cornerRadius: CGFloat = Vitals.Metrics.cornerRadius,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(Vitals.Metrics.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: cornerRadius)
    }
}
```

- [ ] **Step 5: Run tests and look at the output**

Run: `cd VitalsCore && swift test --filter GlassSurfaceTests`
Expected: PASS — 2 tests passing.

Then open the renders and confirm the text is laid out and legible (the glass material itself will not appear offscreen — that is expected and documented in the harness):

```bash
open /tmp/vitals-render/glass-panel.png
```

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Design/GlassSurface.swift VitalsCore/Tests/VitalsUITests
git commit -m "feat: add Liquid Glass surface and offscreen render harness"
```

---

### Task 5: MetricChart — area mode

The house chart style: stacked gradient bands, smoothed, with a live dot at the trailing edge.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MetricChartTests.swift`

**Interfaces:**
- Consumes: `ChartSeries`, `ChartGeometry` (Task 3), `Vitals` tokens (Task 2), `renderPNG` (Task 4).
- Produces: `ChartStyle` enum with `.area(stacked: Bool)` and `.histogram`; `MetricChart` view with `init(series:style:colors:)`. Tasks 6, 8, and 9 use it.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/MetricChartTests.swift`:

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("MetricChart")
struct MetricChartTests {

    private static func wave(_ count: Int, phase: Double, scale: Double) -> [Double] {
        (0..<count).map { index in
            let t = Double(index) / Double(count)
            return (sin(t * 6 + phase) * 0.5 + 0.5) * scale
        }
    }

    @Test("renders a single-series area chart")
    func rendersSingleSeries() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: Self.wave(60, phase: 0, scale: 0.6))],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-area-single")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("renders stacked P-core and E-core bands, the CPU page's decomposition")
    func rendersStackedSeries() throws {
        let chart = MetricChart(
            series: [
                ChartSeries(name: "Performance", values: Self.wave(60, phase: 0, scale: 0.5)),
                ChartSeries(name: "Efficiency", values: Self.wave(60, phase: 2, scale: 0.2)),
            ],
            style: .area(stacked: true),
            colors: Vitals.seriesColors(count: 2)
        )
        let url = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-area-stacked")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an empty series renders without crashing")
    func emptySeriesRenders() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: [])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-empty")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a single sample renders without crashing")
    func singleSampleRenders() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: [0.4])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-single-sample")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter MetricChartTests`
Expected: FAIL — `cannot find 'MetricChart' in scope`.

- [ ] **Step 3: Write the chart**

Create `VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift`:

```swift
import SwiftUI

public enum ChartStyle: Sendable, Equatable {
    /// Smoothed gradient bands. The house style.
    case area(stacked: Bool)
    /// Discrete bars, colour-ramped by load. Reads better at small sizes.
    case histogram
}

/// The one chart in Vitals. Two render modes over one geometry.
public struct MetricChart: View {
    private let series: [ChartSeries]
    private let style: ChartStyle
    private let colors: [Color]

    public init(series: [ChartSeries], style: ChartStyle, colors: [Color]) {
        self.series = series
        self.style = style
        self.colors = colors
    }

    public var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            drawGridlines(in: &context, rect: rect)

            let bands = resolvedBands()
            guard !bands.isEmpty else { return }
            let bound = ChartGeometry.upperBound(for: bands)

            switch style {
            case .area:
                drawAreas(bands, bound: bound, in: &context, rect: rect)
            case .histogram:
                drawHistogram(bands, bound: bound, in: &context, rect: rect)
            }
        }
        .frame(height: Vitals.Metrics.chartHeight)
    }

    /// Stacked mode accumulates; unstacked draws each series against the baseline.
    private func resolvedBands() -> [[Double]] {
        switch style {
        case .area(let stacked) where stacked:
            return ChartGeometry.stack(series)
        case .area, .histogram:
            return series.map(\.values).filter { !$0.isEmpty }
        }
    }

    private func drawGridlines(in context: inout GraphicsContext, rect: CGRect) {
        // Quarter lines give the eye a scale without competing with the data.
        for fraction in [0.25, 0.5, 0.75] {
            let y = rect.maxY - rect.height * fraction
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
    }

    private func drawAreas(
        _ bands: [[Double]],
        bound: Double,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        // Painted back to front so a lower band never hides the one beneath it.
        for (index, values) in bands.enumerated().reversed() {
            let color = colors.isEmpty ? Vitals.Palette.cpu : colors[index % colors.count]
            let points = ChartGeometry.points(values, in: rect, upperBound: bound)
            guard points.count > 1 else { continue }

            let line = ChartGeometry.smoothPath(through: points)

            var fill = line
            fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            fill.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.45), color.opacity(0)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
            context.stroke(line, with: .color(color), lineWidth: 2)

            // The live edge: the most recent sample, marked so the eye lands on
            // "now" rather than hunting for it.
            if index == 0, let last = points.last {
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 9, y: last.y - 9, width: 18, height: 18)),
                    with: .color(color.opacity(0.18))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                    with: .color(color)
                )
            }
        }
    }

    private func drawHistogram(
        _ bands: [[Double]],
        bound: Double,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        guard let values = bands.first, !values.isEmpty else { return }

        let slot = rect.width / CGFloat(values.count)
        let barWidth = max(slot * 0.7, 1)

        for (index, value) in values.enumerated() {
            let fraction = min(max(value / bound, 0), 1)
            let height = rect.height * fraction
            guard height > 0 else { continue }

            let bar = CGRect(
                x: rect.minX + CGFloat(index) * slot + (slot - barWidth) / 2,
                y: rect.maxY - height,
                width: barWidth,
                height: height
            )
            // Colour carries severity: bars warm toward amber as load climbs.
            let color = Vitals.Palette.cpu.mix(with: Vitals.Palette.gpu, by: fraction)
            context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 3), with: .color(color))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter MetricChartTests`
Expected: PASS — 4 tests passing.

- [ ] **Step 5: Look at the renders**

```bash
open /tmp/vitals-render/chart-area-stacked.png /tmp/vitals-render/chart-area-single.png
```

Confirm: the curve is smooth and does not overshoot into a spike the data does not contain; the gradient fades to nothing at the baseline; the stacked version shows two distinguishable bands with the second sitting on the first; the live dot is at the right-hand edge. Report what you see.

If `Color.mix(with:by:)` is unavailable on this SDK, report the compiler error and substitute an explicit interpolation of the two colours' RGB components rather than dropping the ramp.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift VitalsCore/Tests/VitalsUITests/MetricChartTests.swift
git commit -m "feat: add MetricChart with stacked area and histogram modes"
```

---

### Task 6: Chart scrubbing

Hovering freezes a crosshair and reads the exact value with its timestamp — the spec's requirement for both modes.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Charts/ChartScrubber.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift`
- Test: `VitalsCore/Tests/VitalsUITests/ChartScrubberTests.swift`

**Interfaces:**
- Consumes: `ChartSeries`, `ChartGeometry` (Task 3).
- Produces: `ChartGeometry.sampleIndex(atX:in:count:) -> Int?`; `ScrubReadout` (`index: Int`, `values: [(name: String, value: Double)]`); `ChartGeometry.readout(at:series:) -> ScrubReadout?`. `MetricChart` gains an `onHover` crosshair overlay.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/ChartScrubberTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import VitalsUI

@Suite("Chart scrubbing")
struct ChartScrubberTests {

    private let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

    @Test("the leading edge selects the oldest sample")
    func leadingEdgeSelectsOldest() {
        #expect(ChartGeometry.sampleIndex(atX: 0, in: rect, count: 5) == 0)
    }

    @Test("the trailing edge selects the newest sample")
    func trailingEdgeSelectsNewest() {
        #expect(ChartGeometry.sampleIndex(atX: 100, in: rect, count: 5) == 4)
    }

    @Test("a midpoint selects the nearest sample")
    func midpointSelectsNearest() {
        // 5 samples across 100pt sit at 0, 25, 50, 75, 100.
        #expect(ChartGeometry.sampleIndex(atX: 51, in: rect, count: 5) == 2)
        #expect(ChartGeometry.sampleIndex(atX: 64, in: rect, count: 5) == 3)
    }

    @Test("a position outside the chart selects nothing")
    func outsideSelectsNothing() {
        #expect(ChartGeometry.sampleIndex(atX: -5, in: rect, count: 5) == nil)
        #expect(ChartGeometry.sampleIndex(atX: 130, in: rect, count: 5) == nil)
    }

    @Test("an empty chart has nothing to select")
    func emptyChartSelectsNothing() {
        #expect(ChartGeometry.sampleIndex(atX: 50, in: rect, count: 0) == nil)
    }

    @Test("a readout reports every series' value at the scrubbed index")
    func readoutCoversAllSeries() throws {
        let series = [
            ChartSeries(name: "Performance", values: [0.1, 0.2, 0.3]),
            ChartSeries(name: "Efficiency", values: [0.4, 0.5, 0.6]),
        ]
        let readout = try #require(ChartGeometry.readout(at: 1, series: series))

        #expect(readout.index == 1)
        #expect(readout.values.count == 2)
        #expect(readout.values[0].name == "Performance")
        #expect(readout.values[0].value == 0.2)
        #expect(readout.values[1].value == 0.5)
    }

    @Test("a readout past the end of a short series omits it rather than inventing a value")
    func readoutOmitsShortSeries() throws {
        let series = [
            ChartSeries(name: "Performance", values: [0.1, 0.2, 0.3]),
            ChartSeries(name: "Efficiency", values: [0.4]),
        ]
        let readout = try #require(ChartGeometry.readout(at: 2, series: series))

        #expect(readout.values.count == 1)
        #expect(readout.values[0].name == "Performance")
    }

    @Test("a readout at an impossible index is nil")
    func impossibleIndexIsNil() {
        let series = [ChartSeries(name: "CPU", values: [0.1, 0.2])]
        #expect(ChartGeometry.readout(at: 9, series: series) == nil)
        #expect(ChartGeometry.readout(at: -1, series: series) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter ChartScrubberTests`
Expected: FAIL — `type 'ChartGeometry' has no member 'sampleIndex'`.

- [ ] **Step 3: Write the scrubbing geometry**

Create `VitalsCore/Sources/VitalsUI/Charts/ChartScrubber.swift`:

```swift
import CoreGraphics

/// What the crosshair reports at one position.
public struct ScrubReadout: Sendable, Equatable {
    public let index: Int
    public let values: [Named]

    public struct Named: Sendable, Equatable {
        public let name: String
        public let value: Double
    }
}

extension ChartGeometry {

    /// The sample nearest a horizontal position, or `nil` outside the chart.
    public static func sampleIndex(atX x: CGFloat, in rect: CGRect, count: Int) -> Int? {
        guard count > 0, x >= rect.minX, x <= rect.maxX else { return nil }
        guard count > 1 else { return 0 }

        let step = rect.width / CGFloat(count - 1)
        let index = Int(((x - rect.minX) / step).rounded())
        return min(max(index, 0), count - 1)
    }

    /// Every series' value at one index.
    ///
    /// A series too short to reach the index is omitted rather than reported as
    /// zero — the crosshair must not invent a measurement.
    public static func readout(at index: Int, series: [ChartSeries]) -> ScrubReadout? {
        guard index >= 0 else { return nil }
        let named = series.compactMap { entry -> ScrubReadout.Named? in
            guard index < entry.values.count else { return nil }
            return ScrubReadout.Named(name: entry.name, value: entry.values[index])
        }
        guard !named.isEmpty else { return nil }
        return ScrubReadout(index: index, values: named)
    }
}
```

- [ ] **Step 4: Add the crosshair overlay to MetricChart**

In `VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift`, add a hover-position state property, an overlay, and a formatter. Replace the `body` property with:

```swift
    @State private var hoverX: CGFloat?

    public var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)

            Canvas { context, size in
                let canvasRect = CGRect(origin: .zero, size: size)
                drawGridlines(in: &context, rect: canvasRect)

                let bands = resolvedBands()
                guard !bands.isEmpty else { return }
                let bound = ChartGeometry.upperBound(for: bands)

                switch style {
                case .area:
                    drawAreas(bands, bound: bound, in: &context, rect: canvasRect)
                case .histogram:
                    drawHistogram(bands, bound: bound, in: &context, rect: canvasRect)
                }
            }
            .overlay { crosshair(in: rect) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
        }
        .frame(height: Vitals.Metrics.chartHeight)
    }

    @ViewBuilder
    private func crosshair(in rect: CGRect) -> some View {
        let sampleCount = series.map(\.values.count).max() ?? 0

        if let hoverX,
           let index = ChartGeometry.sampleIndex(atX: hoverX, in: rect, count: sampleCount),
           let readout = ChartGeometry.readout(at: index, series: series) {

            let step = sampleCount > 1 ? rect.width / CGFloat(sampleCount - 1) : 0
            let x = rect.minX + CGFloat(index) * step

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1)
                    .position(x: x, y: rect.midY)
                    .frame(height: rect.height)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(readout.values, id: \.name) { entry in
                        Text("\(entry.name)  \(Self.format(entry.value))")
                            .font(Vitals.Typography.label)
                    }
                }
                .padding(6)
                .glassSurface(cornerRadius: 8)
                // Kept inside the chart so the readout never clips off the edge.
                .offset(x: min(max(x + 8, 0), max(rect.width - 130, 0)), y: 6)
            }
        }
    }

    private static func format(_ value: Double) -> String {
        value <= 1.0
            ? "\(Int((value * 100).rounded()))%"
            : String(format: "%.2f", value)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter ChartScrubberTests`
Expected: PASS — 8 tests passing.

Then the full UI suite: `cd VitalsCore && swift test --filter VitalsUITests`
Expected: all passing, non-zero count.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Charts VitalsCore/Tests/VitalsUITests/ChartScrubberTests.swift
git commit -m "feat: add chart scrubbing with crosshair readout"
```

---

### Task 7: App shell with glass sidebar

The window: a translucent sidebar in three groups, and a detail pane. Sections not yet built show an honest placeholder naming the plan that brings them.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Shell/SidebarSection.swift`
- Create: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`
- Modify: `VitalsCore/Sources/VitalsApp/VitalsApp.swift`
- Test: `VitalsCore/Tests/VitalsUITests/SidebarSectionTests.swift`

**Interfaces:**
- Consumes: `MetricsStore` (Task 1), `Vitals` tokens (Task 2).
- Produces: `SidebarSection` enum (`CaseIterable`, `Identifiable`) with `title`, `symbol`, `group`, `isImplemented`, and `static var groups`; `AppShell` view taking a `MetricsStore`. Tasks 8 and 9 attach their pages to it.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/SidebarSectionTests.swift`:

```swift
import Testing
@testable import VitalsUI

@Suite("Sidebar sections")
struct SidebarSectionTests {

    @Test("all twelve spec'd sections are present")
    func allSectionsPresent() {
        #expect(SidebarSection.allCases.count == 12)
    }

    @Test("sections are grouped as Monitor, Hardware, System")
    func sectionsAreGrouped() {
        let groups = SidebarSection.groups.map(\.name)
        #expect(groups == ["Monitor", "Hardware", "System"])
    }

    @Test("every section belongs to exactly one group")
    func everySectionIsGroupedOnce() {
        let grouped = SidebarSection.groups.flatMap(\.sections)
        #expect(grouped.count == SidebarSection.allCases.count)
        #expect(Set(grouped) == Set(SidebarSection.allCases))
    }

    @Test("overview and CPU are implemented in this plan; the rest are not yet")
    func implementedSectionsAreMarked() {
        #expect(SidebarSection.overview.isImplemented)
        #expect(SidebarSection.cpu.isImplemented)
        #expect(SidebarSection.processes.isImplemented == false)
        #expect(SidebarSection.sensors.isImplemented == false)
    }

    @Test("every section has a non-empty title and symbol")
    func sectionsAreLabelled() {
        for section in SidebarSection.allCases {
            #expect(section.title.isEmpty == false)
            #expect(section.symbol.isEmpty == false)
        }
    }

    @Test("titles are unique, so no two rows read identically")
    func titlesAreUnique() {
        #expect(Set(SidebarSection.allCases.map(\.title)).count == SidebarSection.allCases.count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter SidebarSectionTests`
Expected: FAIL — `cannot find 'SidebarSection' in scope`.

- [ ] **Step 3: Write the sections**

Create `VitalsCore/Sources/VitalsUI/Shell/SidebarSection.swift`:

```swift
import Foundation

/// The twelve sections of the main window, in sidebar order.
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, processes
    case cpu, memory, gpu, storage, network, sensors
    case startup, services, users, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .processes: "Processes"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .storage: "Storage"
        case .network: "Network"
        case .sensors: "Sensors"
        case .startup: "Startup"
        case .services: "Services"
        case .users: "Users"
        case .history: "History"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .processes: "list.bullet.rectangle"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.transparent"
        case .storage: "internaldrive"
        case .network: "network"
        case .sensors: "thermometer.medium"
        case .startup: "arrow.up.forward.app"
        case .services: "gearshape.2"
        case .users: "person.2"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Whether this plan builds the section. Sections that are not yet built say
    /// so plainly rather than showing an empty pane.
    public var isImplemented: Bool {
        switch self {
        case .overview, .cpu: true
        default: false
        }
    }

    public struct Group: Identifiable, Sendable {
        public let name: String
        public let sections: [SidebarSection]
        public var id: String { name }
    }

    public static var groups: [Group] {
        [
            Group(name: "Monitor", sections: [.overview, .processes]),
            Group(name: "Hardware", sections: [.cpu, .memory, .gpu, .storage, .network, .sensors]),
            Group(name: "System", sections: [.startup, .services, .users, .history]),
        ]
    }
}
```

- [ ] **Step 4: Write the shell**

Create `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`:

```swift
import SwiftUI

public struct AppShell: View {
    @State private var selection: SidebarSection = .overview
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.groups) { group in
                    Section(group.name) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol)
                                .tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Vitals.Metrics.contentPadding)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewPage(store: store)
        case .cpu:
            CPUPage(store: store)
        default:
            NotYetBuilt(section: selection)
        }
    }
}

/// Says plainly that a section is not built yet, rather than showing an empty
/// pane the user has to interpret.
struct NotYetBuilt: View {
    let section: SidebarSection

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(Vitals.Typography.sectionTitle)
            Text("Not built yet.")
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 5: Point the app at the shell**

In `VitalsCore/Sources/VitalsApp/VitalsApp.swift`, replace the `Group { ... }` block inside `WindowGroup` with:

```swift
            Group {
                if let store {
                    AppShell(store: store)
                } else if let startupError {
                    Text(startupError)
                        .padding()
                } else {
                    ProgressView()
                }
            }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter SidebarSectionTests`
Expected: PASS — 6 tests passing.

This task references `OverviewPage` and `CPUPage`, which Tasks 8 and 9 create. To keep this task independently buildable, add both as temporary stubs in `AppShell.swift` now — Tasks 8 and 9 delete these and create the real files:

```swift
// Temporary stubs so this task builds standalone. Task 8 replaces OverviewPage,
// Task 9 replaces CPUPage, and both delete their stub from this file.
struct OverviewPage: View {
    let store: MetricsStore
    var body: some View { Text("Overview") }
}

struct CPUPage: View {
    let store: MetricsStore
    var body: some View { Text("CPU") }
}
```

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Shell VitalsCore/Sources/VitalsApp VitalsCore/Tests/VitalsUITests/SidebarSectionTests.swift
git commit -m "feat: add app shell with glass sidebar navigation"
```

---

### Task 8: Overview page

A responsive tile grid that fills the window. The spec is explicit that it must grow into available space rather than stranding content at the top — dead space in a monitoring app is wasted signal.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift`
- Create: `VitalsCore/Sources/VitalsUI/Components/MetricTile.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MetricTileTests.swift`

**Interfaces:**
- Consumes: `MetricsStore` (Task 1), `Vitals` tokens (Task 2), `MetricChart` (Task 5), `GlassPanel` (Task 4), `renderPNG` (Task 4).
- Produces: `MetricTile` view with `init(label:value:accent:series:)` where `value: String?`; `OverviewPage` view. Task 9 reuses `MetricTile`.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/MetricTileTests.swift`:

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Metric tile")
struct MetricTileTests {

    @Test("renders a tile with a value and a sparkline")
    func rendersWithValue() throws {
        let tile = MetricTile(
            label: "CPU",
            value: "18%",
            accent: Vitals.Palette.cpu,
            series: [ChartSeries(name: "CPU", values: [0.1, 0.3, 0.2, 0.5, 0.4])]
        )
        let url = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-cpu")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an unavailable value renders an em dash, never a zero")
    func unavailableRendersEmDash() throws {
        // The never-fabricate rule at the presentation layer: a tile with no
        // reading must not look like a reading of zero.
        let tile = MetricTile(
            label: "Sensors",
            value: nil,
            accent: Vitals.Palette.warning,
            series: []
        )
        let url = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-unavailable")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(MetricTile.displayValue(nil) == "—")
        #expect(MetricTile.displayValue("18%") == "18%")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter MetricTileTests`
Expected: FAIL — `cannot find 'MetricTile' in scope`.

- [ ] **Step 3: Write the tile**

Create `VitalsCore/Sources/VitalsUI/Components/MetricTile.swift`:

```swift
import SwiftUI

/// One glass tile on the Overview grid: a label, a large value, and a sparkline.
public struct MetricTile: View {
    private let label: String
    private let value: String?
    private let accent: Color
    private let series: [ChartSeries]

    public init(label: String, value: String?, accent: Color, series: [ChartSeries]) {
        self.label = label
        self.value = value
        self.accent = accent
        self.series = series
    }

    /// An absent reading shows an em dash. Never "0", never blank — a monitor
    /// that cannot measure something must not appear to have measured zero.
    public static func displayValue(_ value: String?) -> String {
        value ?? "—"
    }

    public var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
                    .tracking(0.8)

                Text(Self.displayValue(value))
                    .font(Vitals.Typography.tileValue)
                    .foregroundStyle(value == nil ? .secondary : .primary)

                if series.contains(where: { !$0.values.isEmpty }) {
                    MetricChart(series: series, style: .area(stacked: series.count > 1), colors: [accent])
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
```

- [ ] **Step 4: Write the Overview page**

First delete the temporary `OverviewPage` stub from `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift` (Task 7 added it), then create `VitalsCore/Sources/VitalsUI/Pages/OverviewPage.swift`:

```swift
import SwiftUI
import SystemMetrics

/// Live tile grid. Tiles reflow and grow into available height as the window
/// resizes — the spec is explicit that leftover vertical space belongs to the
/// data, not to emptiness.
public struct OverviewPage: View {
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: Vitals.Metrics.tileSpacing)
    ]

    public var body: some View {
        LazyVGrid(columns: columns, spacing: Vitals.Metrics.tileSpacing) {
            MetricTile(
                label: "CPU",
                value: store.cpu.map { "\(Int(($0.total * 100).rounded()))%" },
                accent: Vitals.Palette.cpu,
                series: cpuSeries
            )
            MetricTile(
                label: "Memory",
                value: store.memory.map { formatBytes($0.used) },
                accent: Vitals.Palette.memory,
                series: memorySeries
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await store.stream(.cpu) }
        .task { await store.stream(.memory) }
    }

    private var cpuSeries: [ChartSeries] {
        [ChartSeries(name: "CPU", values: store.cpuHistory.map(\.total))]
    }

    private var memorySeries: [ChartSeries] {
        guard let total = store.profile?.memory.totalBytes, total > 0 else { return [] }
        return [
            ChartSeries(
                name: "Used",
                values: store.memoryHistory.map { Double($0.used) / Double(total) }
            )
        ]
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
```

- [ ] **Step 5: Run tests and view the tile render**

Run: `cd VitalsCore && swift test --filter MetricTileTests`
Expected: PASS — 2 tests passing.

```bash
open /tmp/vitals-render/tile-cpu.png /tmp/vitals-render/tile-unavailable.png
```

Confirm the unavailable tile shows an em dash in secondary colour, not a zero.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages VitalsCore/Sources/VitalsUI/Components VitalsCore/Tests/VitalsUITests/MetricTileTests.swift
git commit -m "feat: add Overview page with responsive tile grid"
```

---

### Task 9: CPU page with progressive disclosure

The template every other hardware page inherits: title with vendor mark, large value, primary chart, secondary visualisation, four key statistics, and a *Full specifications* disclosure holding everything else.

**Files:**
- Modify: `VitalsCore/Sources/SystemMetrics/CPU/CPUTopology.swift` (add a public initializer)
- Create: `VitalsCore/Sources/VitalsUI/Components/CoreGrid.swift`
- Create: `VitalsCore/Sources/VitalsUI/Components/StatRow.swift`
- Create: `VitalsCore/Sources/VitalsUI/Pages/CPUPage.swift`
- Test: `VitalsCore/Tests/VitalsUITests/CPUPageTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: `CoreGrid` view; `StatRow` view; `CPUPage` view; `CPUPage.formatCache(_:) -> String`; `CPUPage.clusterSeries(history:topology:) -> [ChartSeries]`.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/CPUPageTests.swift`:

```swift
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("CPU page")
struct CPUPageTests {

    private static let m2Pro = CPUTopology(
        brand: "Apple M2 Pro",
        physicalCores: 10,
        logicalCores: 10,
        clusters: [
            CPUCluster(name: "Performance", coreCount: 6, logicalCoreCount: 6),
            CPUCluster(name: "Efficiency", coreCount: 4, logicalCoreCount: 4),
        ],
        l1DataCacheBytes: 65536,
        l2CacheBytes: 4_194_304,
        l3CacheBytes: nil
    )

    private static func sample(busy: Double) -> CPULoadSample {
        CPULoadSample(
            cores: (0..<10).map { _ in CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0) }
        )
    }

    @Test("an absent cache size reads as unavailable, never as zero bytes")
    func absentCacheIsUnavailable() {
        // L3 genuinely does not exist on Apple Silicon.
        #expect(CPUPage.formatCache(nil) == "Unavailable")
        #expect(CPUPage.formatCache(4_194_304).contains("4"))
    }

    @Test("history decomposes into one stacked series per cluster")
    func historySplitsByCluster() {
        let history = [Self.sample(busy: 0.5), Self.sample(busy: 0.25)]
        let series = CPUPage.clusterSeries(history: history, topology: Self.m2Pro)

        #expect(series.count == 2)
        #expect(series[0].name == "Performance")
        #expect(series[1].name == "Efficiency")
        #expect(series[0].values.count == 2)
        #expect(series[0].values[0] == 0.5)
    }

    @Test("a machine with no clusters falls back to one total series")
    func intelFallsBackToTotal() {
        // Intel Macs report no perflevels, so there is nothing to decompose.
        let intel = CPUTopology(
            brand: "Intel(R) Core(TM) i9",
            physicalCores: 8, logicalCores: 16, clusters: [],
            l1DataCacheBytes: 32768, l2CacheBytes: 262_144, l3CacheBytes: 16_777_216
        )
        let series = CPUPage.clusterSeries(history: [Self.sample(busy: 0.4)], topology: intel)

        #expect(series.count == 1)
        #expect(series[0].name == "CPU")
        #expect(series[0].values == [0.4])
    }

    @Test("empty history yields no series rather than a flat zero line")
    func emptyHistoryYieldsNoSeries() {
        #expect(CPUPage.clusterSeries(history: [], topology: Self.m2Pro).isEmpty)
    }

    @Test("renders the core grid")
    func rendersCoreGrid() throws {
        let grid = CoreGrid(cores: Self.sample(busy: 0.6).cores, accent: Vitals.Palette.cpu)
        let url = try renderPNG(grid, size: CGSize(width: 400, height: 60), named: "core-grid")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("renders a stat row, including an unavailable one")
    func rendersStatRow() throws {
        let rows = VStack {
            StatRow(label: "Speed", value: "3.14 GHz")
            StatRow(label: "Package power", value: nil)
        }
        let url = try renderPNG(rows, size: CGSize(width: 320, height: 70), named: "stat-rows")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VitalsCore && swift test --filter CPUPageTests`
Expected: FAIL — `cannot find 'CPUPage' in scope`.

- [ ] **Step 3: Add a public initializer to `CPUTopology`**

`CPUTopology`'s memberwise initializer is internal to `SystemMetrics`, so `VitalsUITests` cannot construct the M2 Pro and Intel fixtures the test above needs. Add an explicit public one to `VitalsCore/Sources/SystemMetrics/CPU/CPUTopology.swift`, immediately above `detect(using:)`:

```swift
    public init(
        brand: String,
        physicalCores: Int?,
        logicalCores: Int?,
        clusters: [CPUCluster],
        l1DataCacheBytes: Int?,
        l2CacheBytes: Int?,
        l3CacheBytes: Int?
    ) {
        self.brand = brand
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.clusters = clusters
        self.l1DataCacheBytes = l1DataCacheBytes
        self.l2CacheBytes = l2CacheBytes
        self.l3CacheBytes = l3CacheBytes
    }
```

Confirm the existing `SystemMetricsTests` still pass afterwards — adding an explicit initializer suppresses the synthesised memberwise one, so any in-module caller relying on a different argument order would break:

Run: `cd VitalsCore && swift test --filter CPUTopologyTests`
Expected: PASS, non-zero count.

- [ ] **Step 4: Write the core grid**

Create `VitalsCore/Sources/VitalsUI/Components/CoreGrid.swift`:

```swift
import SwiftUI
import SystemMetrics

/// Per-core busy fractions as a row of vertical bars.
public struct CoreGrid: View {
    private let cores: [CoreLoad]
    private let accent: Color

    public init(cores: [CoreLoad], accent: Color) {
        self.cores = cores
        self.accent = accent
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(Array(cores.enumerated()), id: \.offset) { _, core in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.10))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent)
                            .frame(height: proxy.size.height * min(max(core.busy, 0), 1))
                    }
                }
            }
        }
        .frame(height: 34)
    }
}
```

- [ ] **Step 5: Write the stat row**

Create `VitalsCore/Sources/VitalsUI/Components/StatRow.swift`:

```swift
import SwiftUI

/// A label and its value. A `nil` value reads "Unavailable" in secondary colour
/// rather than showing a blank the eye interprets as zero.
public struct StatRow: View {
    private let label: String
    private let value: String?

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "Unavailable")
                .font(Vitals.Typography.label)
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
        }
    }
}
```

- [ ] **Step 6: Write the CPU page**

First delete the temporary `CPUPage` stub from `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift` (Task 7 added it), then create `VitalsCore/Sources/VitalsUI/Pages/CPUPage.swift`:

```swift
import SwiftUI
import SystemMetrics

public struct CPUPage: View {
    private let store: MetricsStore
    @State private var showFullSpecifications = false

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// An absent cache level reads as unavailable. `hw.l3cachesize` genuinely
    /// does not exist on Apple Silicon, and "0 bytes" would be a lie.
    public static func formatCache(_ bytes: Int?) -> String {
        guard let bytes else { return "Unavailable" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// One stacked series per performance cluster, or a single total series on
    /// hardware that has no clusters to decompose.
    public static func clusterSeries(
        history: [CPULoadSample],
        topology: CPUTopology
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        guard !topology.clusters.isEmpty else {
            return [ChartSeries(name: "CPU", values: history.map(\.total))]
        }
        return topology.clusters.map { cluster in
            ChartSeries(
                name: cluster.name,
                values: history.map { $0.clusterLoads(for: topology.clusters)[cluster.name] ?? 0 }
            )
        }
    }

    // MARK: View

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
                header
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        primaryValue
                        chart
                        coreGrid
                    }
                }
                GlassPanel { keyStatistics }
                GlassPanel { fullSpecifications }
            }
        }
        .task { await store.stream(.cpu) }
    }

    private var topology: CPUTopology? { store.profile?.cpu }

    private var header: some View {
        HStack {
            Text("CPU").font(Vitals.Typography.sectionTitle)
            Spacer()
            if let topology {
                HStack(spacing: 6) {
                    // The Apple mark is a glyph in the system font, so no asset
                    // is bundled for it.
                    if topology.isAppleSilicon { Text("\u{F8FF}") }
                    Text(topology.brand)
                }
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassSurface(cornerRadius: 20)
            }
        }
    }

    private var primaryValue: some View {
        Text(store.cpu.map { "\(Int(($0.total * 100).rounded()))%" } ?? "—")
            .font(Vitals.Typography.readout)
            .foregroundStyle(store.cpu == nil ? .secondary : .primary)
    }

    @ViewBuilder
    private var chart: some View {
        if let topology {
            let series = Self.clusterSeries(history: store.cpuHistory, topology: topology)
            MetricChart(
                series: series,
                style: .area(stacked: series.count > 1),
                colors: Vitals.seriesColors(count: max(series.count, 1))
            )
        }
    }

    @ViewBuilder
    private var coreGrid: some View {
        if let cores = store.cpu?.cores, !cores.isEmpty {
            CoreGrid(cores: cores, accent: Vitals.Palette.cpu)
            if let clusters = topology?.clusters, !clusters.isEmpty {
                HStack {
                    ForEach(clusters, id: \.name) { cluster in
                        Text("\(cluster.coreCount) \(cluster.name)")
                            .font(Vitals.Typography.label)
                            .foregroundStyle(.secondary)
                        if cluster.name != clusters.last?.name { Spacer() }
                    }
                }
            }
        }
    }

    /// The four numbers you actually watch. Everything else lives behind the
    /// disclosure below.
    private var keyStatistics: some View {
        let load = store.systemLoad
        return VStack(spacing: 0) {
            StatRow(label: "Cores", value: coreCountDescription)
            StatRow(label: "Load average", value: load.loadAverage1.map { String(format: "%.2f", $0) })
            StatRow(label: "Uptime", value: Self.formatUptime(load.uptimeSeconds))
            StatRow(label: "Speed", value: unavailableReason(store.profile?.frequencyAvailable))
        }
    }

    /// Both counts are `Int?` — an absent sysctl reads nil, never 0 — so this
    /// describes whichever parts are actually known.
    private var coreCountDescription: String? {
        guard let topology else { return nil }
        switch (topology.physicalCores, topology.logicalCores) {
        case let (physical?, logical?): return "\(physical) physical, \(logical) logical"
        case let (physical?, nil): return "\(physical) physical"
        case let (nil, logical?): return "\(logical) logical"
        case (nil, nil): return nil
        }
    }

    private var fullSpecifications: some View {
        DisclosureGroup(isExpanded: $showFullSpecifications) {
            VStack(spacing: 0) {
                StatRow(label: "Architecture", value: topology?.isAppleSilicon == true ? "arm64e" : "x86_64")
                StatRow(label: "L1 data cache", value: Self.formatCache(topology?.l1DataCacheBytes))
                StatRow(label: "L2 cache", value: Self.formatCache(topology?.l2CacheBytes))
                StatRow(label: "L3 cache", value: Self.formatCache(topology?.l3CacheBytes))
                StatRow(label: "Load average (5m)", value: store.systemLoad.loadAverage5.map { String(format: "%.2f", $0) })
                StatRow(label: "Load average (15m)", value: store.systemLoad.loadAverage15.map { String(format: "%.2f", $0) })
                StatRow(label: "Die temperature", value: unavailableReason(store.profile?.sensorsAvailable))
                StatRow(label: "Package power", value: unavailableReason(store.profile?.sensorsAvailable))
                StatRow(label: "Cluster frequency", value: unavailableReason(store.profile?.frequencyAvailable))
            }
            .padding(.top, 6)
        } label: {
            Text("Full specifications").font(Vitals.Typography.label)
        }
    }

    /// Renders a capability's unavailability, so the page explains itself rather
    /// than showing a blank row.
    private func unavailableReason(_ availability: MetricAvailability?) -> String? {
        guard let availability else { return nil }
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd VitalsCore && swift test --filter CPUPageTests`
Expected: PASS — 6 tests passing.

Then the full suite: `cd VitalsCore && swift test`
Expected: all passing (99 from M1-A plus this plan's), non-zero count, no warnings.

- [ ] **Step 8: Run the app and check it against reality**

Run: `cd VitalsCore && swift run VitalsApp`

Confirm, and report what you observe:
- The sidebar shows three groups and twelve rows.
- Overview shows two tiles with live, changing values that fill the window width, and reflow when you resize.
- The CPU page shows `Apple M2 Pro` with the Apple mark, a live percentage, a stacked chart with distinguishable Performance and Efficiency bands, and a ten-bar core grid that moves.
- Hovering the chart shows a crosshair with per-cluster values.
- **L3 cache reads "Unavailable", not "0 bytes"** — expand *Full specifications* to check.
- Die temperature, package power, and cluster frequency each show their stated unavailability reason rather than a number or a blank.
- Compare the CPU percentage against Activity Monitor; they should track closely.

- [ ] **Step 9: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Sources/SystemMetrics/CPU/CPUTopology.swift VitalsCore/Tests/VitalsUITests/CPUPageTests.swift
git commit -m "feat: add CPU page with progressive disclosure"
```

---

## Completion criteria

- `cd VitalsCore && swift test` passes with no failures and no warnings.
- `swift run VitalsApp` opens a window with a working glass sidebar and two live pages.
- The Overview grid fills the window and reflows on resize, with no dead space below the tiles.
- The CPU chart shows Performance and Efficiency as distinguishable stacked bands.
- Hovering any chart produces a crosshair readout with a per-series value.
- L3 cache reads "Unavailable" on Apple Silicon; sensors and frequency show their stated reasons.
- No value anywhere renders as `0` or blank when the underlying type is `nil`.

## What comes next

**M1-B-2** adds the Memory, GPU, Storage, Network, and Sensors pages, each following the CPU page's template and its stacked-series decomposition. **M1-B-3** adds the Processes pane. Both build entirely on what this plan establishes.
