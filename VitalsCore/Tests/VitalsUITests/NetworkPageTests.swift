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

    /// The whole point of this test: nothing before it ever constructed a
    /// `NetworkPage` from a `MetricsStore` and rendered it — every prior test
    /// in this file covers only the static, pure `throughputSeries` and
    /// `activeInterfaces` helpers.
    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFullPageFromStore() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler { ["en0": NetworkThroughput(bytesInPerSecond: 2_097_152, bytesOutPerSecond: 1_048_576)] },
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
        // alone was vacuous and why a saturation probe (not `regionHasContent`)
        // is the correct replacement inside a `GlassPanel`. Throughput is an
        // absolute-unit series, which auto-scales its axis to its own peak
        // (`ChartGeometry.upperBound`) — a single-tick history's one reading
        // *is* that peak, so its band always touches the canvas top
        // regardless of the exact value, no tuning needed here.
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion))
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
