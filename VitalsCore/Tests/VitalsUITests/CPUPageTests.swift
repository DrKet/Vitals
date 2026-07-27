import MetricsEngine
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

    /// Wraps samples with a steady 1 Hz cadence, matching what the store holds.
    private static func stamped(
        _ samples: [CPULoadSample],
        from start: TimeInterval = 1000
    ) -> [Timestamped<CPULoadSample>] {
        samples.enumerated().map { index, sample in
            Timestamped(timestamp: start + TimeInterval(index), sample: sample)
        }
    }

    private static func sample(busy: Double) -> CPULoadSample {
        CPULoadSample(
            cores: (0..<10).map { _ in CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0) }
        )
    }

    @Test("an absent cache size reads as unavailable, never as zero bytes")
    func absentCacheIsUnavailable() {
        // L3 genuinely does not exist on Apple Silicon. `Vitals.formatByteCount`
        // hands back `nil` — not the baked-in string "Unavailable" — so
        // `StatRow` is the single place that decides how absence is worded
        // and styled.
        #expect(Vitals.formatByteCount(Int?.none) == nil)
        #expect(Vitals.formatByteCount(4_194_304)?.contains("4") == true)
    }

    @Test("history decomposes into one stacked series per cluster")
    func historySplitsByCluster() {
        let history = Self.stamped([Self.sample(busy: 0.5), Self.sample(busy: 0.25)])
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
        let series = CPUPage.clusterSeries(history: Self.stamped([Self.sample(busy: 0.4)]), topology: intel)

        #expect(series.count == 1)
        #expect(series[0].name == "CPU")
        // `0.4` is not exactly representable in binary floating point, so
        // summing ten cores' busy fractions and dividing by ten lands on
        // 0.39999999999999997 rather than the literal 0.4 — a deterministic
        // IEEE-754 rounding artifact, not flakiness. Compare with tolerance
        // rather than requiring bit-exact equality.
        #expect(series[0].values.count == 1)
        #expect(abs(series[0].values[0] - 0.4) < 1e-9)
    }

    @Test("empty history yields no series rather than a flat zero line")
    func emptyHistoryYieldsNoSeries() {
        #expect(CPUPage.clusterSeries(history: [], topology: Self.m2Pro).isEmpty)
    }

    @Test("a cluster whose logical core count exceeds the sample's actual cores is omitted, never zero-filled")
    func clusterExceedingSampleCoreCountYieldsNoSeries() {
        // `clusterLoads(for:)` walks clusters in order and breaks out of its
        // loop the moment a cluster's logical core count runs past the
        // sample's `cores.count` — so every cluster after the mismatch is
        // simply absent from its result dictionary. This models a topology
        // (10 logical cores) sampled by a source that only reports 6 cores:
        // Performance alone consumes all 6, leaving nothing for Efficiency.
        let mismatched = CPUTopology(
            brand: "Apple M2 Pro",
            physicalCores: 10, logicalCores: 10,
            clusters: [
                CPUCluster(name: "Performance", coreCount: 6, logicalCoreCount: 6),
                CPUCluster(name: "Efficiency", coreCount: 4, logicalCoreCount: 4),
            ],
            l1DataCacheBytes: nil, l2CacheBytes: nil, l3CacheBytes: nil
        )
        let history = Self.stamped([
            CPULoadSample(cores: (0..<6).map { _ in CoreLoad(user: 0.5, system: 0, idle: 0.5, nice: 0) })
        ])
        let series = CPUPage.clusterSeries(history: history, topology: mismatched)

        // Efficiency must be dropped entirely, never rendered as a flat 0%
        // line — that would be a measurement the machine never reported.
        #expect(series.count == 1)
        #expect(series[0].name == "Performance")
    }

    @Test("an available capability with a reading renders that reading, never 'Unavailable'")
    func availableCapabilityRendersItsReading() {
        // The regression this guards: the previous `unavailableReason` helper
        // returned `nil` for `.available` unconditionally, so once a
        // capability like CPU frequency actually starts working, its row
        // would read "Unavailable" forever unless every call site remembered
        // to stop calling that helper. `gatedValue` makes passing a real
        // reading the only way to get anything other than the absent state.
        #expect(CPUPage.gatedValue(.available, measured: "3.49 GHz") == "3.49 GHz")
    }

    @Test("an available capability with no reading yet is distinct from unavailable, though both render absent")
    func availableCapabilityPendingIsNotUnavailableReason() {
        // Still renders as `StatRow`'s "Unavailable" today (there is no
        // reading to show), but this exercises the `.pending` branch
        // specifically so a future call site that wires in real data can't
        // silently fall through the wrong case.
        #expect(CPUPage.gatedValue(.available, measured: nil) == nil)
    }

    @Test("an unavailable capability never renders its reason as if it were a reading")
    func unavailableCapabilityRendersNil() {
        #expect(CPUPage.gatedValue(.unavailable(reason: "test reason"), measured: "should be ignored") == nil)
    }

    @Test("cluster series carry the sample timestamps through to the chart")
    func clusterSeriesCarryTimestamps() throws {
        let history = Self.stamped([Self.sample(busy: 0.5), Self.sample(busy: 0.25)])
        let series = CPUPage.clusterSeries(history: history, topology: Self.m2Pro)

        let performance = try #require(series.first)
        #expect(performance.timestamps == [1000, 1001])
        #expect(performance.timestamps.count == performance.values.count)
    }

    @Test("a break in sampling is detected as a gap rather than drawn through")
    func samplingBreakBecomesAGap() throws {
        // Leaving the page stops sampling; returning must not splice the old
        // run onto the new one as though nothing happened.
        var history = Self.stamped([Self.sample(busy: 0.5), Self.sample(busy: 0.5)])
        history += [
            Timestamped(timestamp: 2000, sample: Self.sample(busy: 0.3)),
            Timestamped(timestamp: 2001, sample: Self.sample(busy: 0.3)),
        ]

        let series = CPUPage.clusterSeries(history: history, topology: Self.m2Pro)
        let performance = try #require(series.first)

        #expect(ChartGeometry.segments(for: performance) == [0..<2, 2..<4])
    }

    @Test("renders the core grid")
    func rendersCoreGrid() throws {
        let grid = CoreGrid(cores: Self.sample(busy: 0.6).cores, accent: Vitals.Palette.cpu)
        // No region probe: per-core bar heights are already covered by
        // `CoreGrid`'s own straightforward geometry, so the harness's
        // whole-image blank check is the right amount of assertion.
        _ = try renderPNG(grid, size: CGSize(width: 400, height: 60), named: "core-grid")
    }

    @Test("renders a stat row, including an unavailable one")
    func rendersStatRow() throws {
        let rows = VStack {
            StatRow(label: "Speed", value: "3.14 GHz")
            StatRow(label: "Package power", value: nil)
        }
        // No region probe: `StatRow`'s wording rule ("Unavailable" vs. a real
        // value) is asserted directly by `StatRowTests`, so this only needs
        // to prove the two-row layout renders without crashing.
        _ = try renderPNG(rows, size: CGSize(width: 320, height: 70), named: "stat-rows")
    }

    /// This machine's real hardware description. `HardwareProfileTests`
    /// already exercises `HardwareProfile.detect()` directly against real
    /// sysctl/`system_profiler` output; reusing it here means the cluster
    /// layout this test feeds through `CPUPage` is honest for whatever Mac
    /// runs the suite, rather than a topology that might not match a
    /// hand-picked sample's core count.
    private static func detectedProfile() throws -> HardwareProfile {
        try HardwareProfile.detect()
    }

    /// The whole point of this test: nothing before it ever constructed a
    /// `CPUPage` from a `MetricsStore` and rendered it. Every prior
    /// `CPUPage` test — including every one above in this file — covers only
    /// the page's static, pure helpers. A page that composed but painted
    /// nothing would have sailed through the whole suite undetected; this is
    /// the first test that would actually catch that.
    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFullPageFromStore() async throws {
        let profile = try Self.detectedProfile()
        let coreCount = profile.cpu.logicalCores ?? profile.cpu.physicalCores ?? 8
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler {
                CPULoadSample(cores: (0..<coreCount).map { _ in
                    CoreLoad(user: 0.4, system: 0.1, idle: 0.5, nice: 0)
                })
            },
            for: .cpu,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: profile)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.count >= 2 }
        task.cancel()

        let rendered = try renderPNG(
            CPUPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "cpu-page-with-data"
        )
        // `fileExists` alone is vacuous here — `renderPNG` already wrote the
        // file and would have thrown otherwise, so this proved nothing about
        // whether the chart actually painted the sampled data. A region probe
        // inside the chart's own canvas is what would actually catch a chart
        // that silently stopped drawing. See `chartCanvasProbeRegion`'s doc
        // comment for why this exact rectangle.
        //
        // A plain `regionHasSaturatedColor` is not enough here: `CoreGrid`
        // paints in this page's own lead accent (CPU blue, the chart's
        // `colors[0]`), so a broken chart whose collapsed layout slides
        // `CoreGrid` up into this rectangle would still "pass" — a false
        // pass a senior review found by hand. Matching only the *other*
        // cluster bands' hues (`colors[1...]`, computed from the real
        // series `CPUPage.clusterSeries` actually produced, so this holds
        // however many performance/efficiency clusters this Mac reports)
        // closes that gap: `CoreGrid` can never paint those hues, only
        // `MetricChart`'s own stacked bands can. See
        // `regionHasSaturatedColor(in:region:matchingHueOf:)`'s doc comment.
        //
        // Every core reports the same 0.5 busy fraction, so on any Mac with
        // two or more performance/efficiency clusters (every Apple Silicon
        // Mac) the stacked cumulative total clamps to the chart's upper
        // bound — the topmost band sits exactly at the canvas top,
        // comfortably inside this probe regardless of how tall the chart
        // actually grows.
        let series = CPUPage.clusterSeries(history: store.cpuHistory, topology: profile.cpu)
        let nonLeadHues = Array(Vitals.seriesColors(startingAt: Vitals.Palette.cpu, count: series.count).dropFirst().map(hue(of:)))
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion, matchingHueOf: nonLeadHues))
    }

    @Test("a freshly constructed page with no samples yet still renders, rather than crashing on nil state")
    func rendersFromEmptyStore() throws {
        // The state a page is actually in for its first second on screen,
        // before any sample has arrived.
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(
            CPUPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "cpu-page-empty-store"
        )
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
