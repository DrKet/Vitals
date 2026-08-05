import MetricsEngine
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
        // Byte-to-MB/s division is floating point, so compare with tolerance
        // rather than `==` — see `StoragePageTests.splitsIntoReadAndWrite` for
        // the same pattern.
        #expect(abs(series[0].values[0] - 2.0) < 1e-9)
        #expect(abs(series[1].values[0] - 1.0) < 1e-9)
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
        let series = NetworkPage.throughputSeries(history: Self.stamped([sample]))
        #expect(abs(series[0].values[0] - 1.0) < 1e-9)
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

    @Test("the busiest interface is not the one activeInterfaces sorts first")
    func firstActiveInterfaceIsNotThePrimaryOne() {
        // Why the header badge no longer derives a name from throughput at
        // all. `activeInterfaces` sorts, so `.first` is alphabetical: with
        // awdl0, bridge0 and en0 all carrying traffic it picks awdl0, even
        // though en0 has five times the volume — and the answer flips as
        // traffic shifts. That is not spec §6.2's stable vendor mark, so the
        // page passes nil rather than guessing.
        //
        // This pins the property that made the old rule wrong. It cannot
        // guard the page's own `vendorName: nil`, which is now a literal at
        // the call site with nothing to call.
        let busy = [
            "awdl0": NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 0),
            "bridge0": NetworkThroughput(bytesInPerSecond: 2000, bytesOutPerSecond: 0),
            "en0": NetworkThroughput(bytesInPerSecond: 5000, bytesOutPerSecond: 0),
        ]
        #expect(NetworkPage.activeInterfaces(busy).first == "awdl0")
        #expect(busy["en0"]?.bytesInPerSecond == 5000)
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

    @Test("an interface that drops out and returns is summed fresh each tick, never carried forward from an earlier one")
    func interfaceDroppingOutAndReturningIsRecomputedEachTick() {
        // Tick 1: en0 and en1 both present.
        // Tick 2: en0 drops out of the dictionary entirely — e.g. it went
        // down, or its counters reset, per `NetworkThroughputTracker`. A
        // per-tick sum over present keys can't distinguish "omitted" from
        // "zero-filled" (both contribute 0 to the total), so this doesn't
        // prove which one happened — only that en0's prior 1 MB/s reading is
        // not carried forward into this tick's sum.
        // Tick 3: en0 reappears with a different reading than before it left,
        // proving it is recomputed fresh rather than treated as a delta
        // against its pre-absence value.
        let history = Self.stamped([
            [
                "en0": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
                "en1": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
            ],
            [
                "en1": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
            ],
            [
                "en0": NetworkThroughput(bytesInPerSecond: 3_145_728, bytesOutPerSecond: 0),
                "en1": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
            ],
        ])
        let down = NetworkPage.throughputSeries(history: history)[0].values

        #expect(abs(down[0] - 2.0) < 1e-9)
        #expect(abs(down[1] - 1.0) < 1e-9)
        #expect(abs(down[2] - 4.0) < 1e-9)
    }

    @Test("a tick whose only interface is loopback leaves nothing to sum, never a fabricated zero")
    func lo0OnlyTickIsAbsentNotZero() {
        // The exact scenario `StandardSamplers.swift`'s `guard
        // !throughput.isEmpty` lets through: a `["lo0": …]` dictionary is
        // non-empty, so it reaches the page, but every entry is excluded.
        // `totalMBs` and the Down/Up stats must treat this the same way the
        // chart already does (`ThroughputBands`'s per-tick exclusion) —
        // nothing left after filtering means absent, not a real-looking
        // "0.00 MB/s".
        let lo0Only = ["lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000)]
        #expect(NetworkPage.realThroughput(lo0Only) == nil)
    }

    @Test("an empty tick has nothing to sum either")
    func emptyTickIsAbsent() {
        #expect(NetworkPage.realThroughput([:]) == nil)
    }

    @Test("a real interface reporting genuine zero traffic is a reading, not withheld")
    func realInterfaceAtZeroIsNotWithheld() {
        // Distinct from the lo0-only case: here a real interface *did*
        // report this tick, and it happened to report no traffic. That is a
        // measurement, so it must survive filtering rather than being
        // conflated with "nothing reported at all".
        let idle = ["en0": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)]
        #expect(NetworkPage.realThroughput(idle) == idle)
    }

    @Test("loopback is dropped from the filtered dictionary when a real interface is also present")
    func loopbackDroppedAlongsideARealInterface() {
        let mixed = [
            "lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000),
            "en0": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
        ]
        #expect(NetworkPage.realThroughput(mixed) == ["en0": mixed["en0"]!])
    }

    @Test("never sampled: Active interfaces reads Unavailable, not a fabricated zero")
    func activeInterfaceCountIsAbsentWhenNeverSampled() {
        #expect(NetworkPage.activeInterfaceCountDisplay(nil) == nil)
    }

    @Test("an lo0-only tick's Active interfaces stat is absent, matching Down/Up drawn from the same empty filtered set")
    func activeInterfaceCountIsAbsentOnLoopbackOnlyTick() {
        // Fix 6: a senior review found this stat previously gated only on
        // `store.network == nil`, so an lo0-only tick (non-nil, but every
        // entry excluded) fell through to a real-looking "0" — a bright,
        // primary-styled reading directly above Down/Up correctly reading
        // "Unavailable" from that exact same tick. All three must agree.
        let lo0Only = ["lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000)]
        #expect(NetworkPage.activeInterfaceCountDisplay(lo0Only) == nil)
        #expect(NetworkPage.realThroughput(lo0Only) == nil)
    }

    @Test("an empty tick's Active interfaces stat is absent too")
    func activeInterfaceCountIsAbsentOnEmptyTick() {
        #expect(NetworkPage.activeInterfaceCountDisplay([:]) == nil)
    }

    @Test("a real interface reporting genuine zero traffic is an honest zero, not withheld")
    func activeInterfaceCountIsGenuineZeroWhenRealInterfaceIsIdle() {
        // Distinct from the lo0-only case: a real, non-excluded interface
        // did report this tick, and simply had nothing to say — that is a
        // measurement, and "0" is what it should read.
        let idle = ["en0": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)]
        #expect(NetworkPage.activeInterfaceCountDisplay(idle) == "0")
    }

    @Test("a real interface carrying traffic is counted")
    func activeInterfaceCountCountsARealInterface() {
        let active = ["en0": NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 0)]
        #expect(NetworkPage.activeInterfaceCountDisplay(active) == "1")
    }

    // MARK: totalThroughputSeries (Overview tile)

    @Test("the tile's total series sums Down and Up into a single line, matching the two stacked bands' own sum")
    func totalSeriesSumsDownAndUp() {
        let history = Self.stamped([
            ["en0": NetworkThroughput(bytesInPerSecond: 2_097_152, bytesOutPerSecond: 1_048_576)]
        ])
        let bands = NetworkPage.throughputSeries(history: history)
        let total = NetworkPage.totalThroughputSeries(history: history)

        #expect(total.count == 1)
        #expect(abs(total[0].values[0] - (bands[0].values[0] + bands[1].values[0])) < 1e-9)
    }

    @Test("loopback is excluded from the total too, not just the bands")
    func totalSeriesExcludesLoopback() {
        let sample = [
            "lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000),
            "en0": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 0),
        ]
        let total = NetworkPage.totalThroughputSeries(history: Self.stamped([sample]))
        #expect(abs(total[0].values[0] - 1.0) < 1e-9)
    }

    @Test("an lo0-only tick yields no total series at all, matching the bands' own empty-tick drop")
    func totalSeriesDropsLoopbackOnlyTick() {
        let lo0Only = ["lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000)]
        #expect(NetworkPage.totalThroughputSeries(history: Self.stamped([lo0Only])).isEmpty)
    }

    @Test("the total series carries timestamps too")
    func totalSeriesCarriesTimestamps() {
        let history = Self.stamped([
            ["en0": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)],
            ["en0": NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)],
        ])
        #expect(NetworkPage.totalThroughputSeries(history: history)[0].timestamps == [1000, 1001])
    }

    @Test("empty history yields no total series")
    func totalSeriesEmptyHistoryYieldsNoSeries() {
        #expect(NetworkPage.totalThroughputSeries(history: []).isEmpty)
    }

    /// The whole point of this test: nothing before it ever constructed a
    /// `NetworkPage` from a `MetricsStore` and rendered it — every prior test
    /// in this file covers only the static, pure `throughputSeries` and
    /// `activeInterfaces` helpers.
    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFullPageFromStore() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            // 4.0 + 0.5 = 4.5 MB/s, deliberately not itself a "nice" bound:
            // `ChartGeometry.niceUpperBound` now rounds an absolute-unit
            // chart's axis up to the nearest 1/2/5x power of ten (5, here)
            // rather than sitting exactly on the peak, so the topmost band no
            // longer touches the canvas top for an arbitrary reading — only
            // for one landing near a rounded bound. 4.5 against a bound of 5
            // is 90% of the chart's height, comfortably inside
            // `chartCanvasProbeRegion` regardless of exactly how tall this
            // page's chart grows (its floor-to-cap range is 132-220pt; see
            // that region's own doc comment) — the earlier 2.0/1.0 MB/s
            // fixture (peak 3, bound 5, 60%) sat right at that region's edge
            // and was intermittently missed depending on rendered height, as
            // seen in `PageRenderRegressionTests`.
            AnySampler { ["en0": NetworkThroughput(bytesInPerSecond: 4_194_304, bytesOutPerSecond: 524_288)] },
            for: .network,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.network) }
        try await waitUntil { store.networkHistory.count >= 2 }
        task.cancel()

        let rendered = try renderPNG(
            NetworkPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "network-page-with-data"
        )
        // See `CPUPageTests.rendersFullPageFromStore` for why `fileExists`
        // alone was vacuous. Throughput is an absolute-unit series; since the
        // stable-axis change it scales to a *rounded* bound
        // (`ChartGeometry.niceUpperBound`), not the raw peak, so the fixture
        // above is chosen to land at 90% of the chart's height rather than
        // exactly 100% — see the comment on the sampler.
        //
        // `regionHasSaturatedColor(in:region:matchingHueOf:)`'s doc comment
        // explains why matching only the non-lead band hue (Up, never Down's
        // lead accent) is what actually proves the chart itself painted
        // here, rather than merely something in the panel — Network has no
        // accent-only secondary component today, but this keeps the same
        // (stronger) discipline as the other four pages' equivalent tests.
        let series = NetworkPage.throughputSeries(history: store.networkHistory)
        let nonLeadHues = Array(Vitals.seriesColors(startingAt: Vitals.Palette.network, count: series.count).dropFirst().map(hue(of:)))
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion, matchingHueOf: nonLeadHues))
    }

    @Test("a freshly constructed page with no samples yet still renders, rather than crashing on nil state")
    func rendersFromEmptyStore() throws {
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(
            NetworkPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "network-page-empty-store"
        )
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
