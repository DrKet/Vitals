import MetricsEngine
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
        // Fractions are computed by dividing UInt64 sample values as Doubles,
        // which is not guaranteed bit-exact, so compare with tolerance rather
        // than `==` — see `CPUPageTests.intelFallsBackToTotal` for the same
        // pattern.
        #expect(abs(series[0].values[0] - 0.2) < 1e-9)
        #expect(abs(series[1].values[0] - 0.3) < 1e-9)
        #expect(abs(series[2].values[0] - 0.1) < 1e-9)
        #expect(abs(series[3].values[0] - 0.4) < 1e-9)
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
        #expect(Vitals.formatByteCount(UInt64?.none) == nil)
        #expect(Vitals.formatByteCount(UInt64(1_073_741_824))?.isEmpty == false)
    }

    /// The whole point of this test: nothing before it ever constructed a
    /// `MemoryPage` from a `MetricsStore` and rendered it — every prior test
    /// in this file covers only the static, pure `breakdownSeries` helper.
    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFullPageFromStore() async throws {
        // Real hardware description (`HardwareProfile.detect()`, exercised
        // directly by `HardwareProfileTests`) so the installed-bytes total
        // this test's fractions are computed against is honest for whatever
        // Mac runs the suite.
        let profile = try HardwareProfile.detect()
        let total = profile.memory.totalBytes
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler {
                // Wired + App + Compressed + Cached sums to 90% of installed
                // memory — high enough that the stacked total's curve sits
                // within the top ~10% of the chart's canvas regardless of how
                // tall it actually renders, which is what makes
                // `chartCanvasProbeRegion` (a fixed rectangle near the canvas
                // top, shared by all five pages' equivalent tests) land on
                // real chart content below. See its doc comment for the full
                // reasoning.
                MemorySample(
                    app: total * 3 / 10, wired: total * 3 / 10, compressed: total / 10, cached: total * 2 / 10,
                    free: total / 10, swapUsed: total / 8, swapTotal: total / 4, pressure: .normal
                )
            },
            for: .memory,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: profile)

        let task = Task { await store.stream(.memory) }
        try await waitUntil { store.memoryHistory.count >= 2 }
        task.cancel()

        let rendered = try renderPNG(
            MemoryPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "memory-page-with-data"
        )
        // See `CPUPageTests.rendersFullPageFromStore` for why `fileExists`
        // alone was vacuous, and
        // `regionHasSaturatedColor(in:region:matchingHueOf:)`'s doc comment
        // for why matching only the non-lead band hues (never the page's own
        // accent) is what actually proves the chart itself painted here,
        // rather than merely something in the panel.
        let series = MemoryPage.breakdownSeries(history: store.memoryHistory, installedBytes: total)
        let nonLeadHues = Array(Vitals.seriesColors(startingAt: Vitals.Palette.memory, count: series.count).dropFirst().map(hue(of:)))
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion, matchingHueOf: nonLeadHues))
    }

    @Test("a freshly constructed page with no samples yet still renders, rather than crashing on nil state")
    func rendersFromEmptyStore() throws {
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(
            MemoryPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "memory-page-empty-store"
        )
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
