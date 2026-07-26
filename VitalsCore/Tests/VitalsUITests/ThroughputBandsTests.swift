import Foundation
import Testing
@testable import VitalsUI

/// Direct coverage of the generic helper shared by `StoragePage` and
/// `NetworkPage`. Domain-specific behaviour (loopback exclusion, dropped
/// devices) is covered per-page in `StoragePageTests`/`NetworkPageTests`;
/// this suite exercises the helper itself against a plain `Double` sample so
/// it stays decoupled from any one hardware domain.
@Suite("Throughput bands")
struct ThroughputBandsTests {

    private static func stamped(_ samples: [[String: Double]]) -> [Timestamped<[String: Double]>] {
        samples.enumerated().map { Timestamped(timestamp: 500 + TimeInterval($0.offset), sample: $0.element) }
    }

    @Test("empty history yields no bands")
    func emptyHistoryYieldsNoBands() {
        let bands = ChartGeometry.throughputBands(
            history: [Timestamped<[String: Double]>](),
            bands: [(name: "A", rate: { $0 })]
        )
        #expect(bands.isEmpty)
    }

    @Test("excluded keys are removed from the sum entirely, not zeroed within it")
    func excludedKeysAreRemovedFromSum() {
        let history = Self.stamped([
            ["keep": 1_048_576, "drop": 9_000_000],
        ])
        let bands = ChartGeometry.throughputBands(
            history: history,
            excluding: ["drop"],
            bands: [(name: "A", rate: { $0 })]
        )
        #expect(abs(bands[0].values[0] - 1.0) < 1e-9)
    }

    @Test("bands are named and ordered exactly as the caller lists them, values converted to MB/s")
    func bandsPreserveCallerOrderAndConvertToMegabytes() {
        let history = Self.stamped([
            ["dev": 2_097_152],
        ])
        let bands = ChartGeometry.throughputBands(
            history: history,
            bands: [
                (name: "First", rate: { $0 }),
                (name: "Second", rate: { $0 / 2 }),
            ]
        )
        #expect(bands.map(\.name) == ["First", "Second"])
        #expect(abs(bands[0].values[0] - 2.0) < 1e-9)
        #expect(abs(bands[1].values[0] - 1.0) < 1e-9)
    }

    @Test("each band carries the history's timestamps")
    func bandsCarryTimestamps() {
        let history = Self.stamped([["dev": 0], ["dev": 0]])
        let bands = ChartGeometry.throughputBands(history: history, bands: [(name: "A", rate: { $0 })])
        #expect(bands[0].timestamps == [500, 501])
    }

    @Test("a key absent from a tick's dictionary contributes nothing that tick, rather than a fabricated zero")
    func absentKeyContributesNothing() {
        let history = Self.stamped([
            ["a": 1_048_576, "b": 1_048_576],
            ["b": 1_048_576],
        ])
        let bands = ChartGeometry.throughputBands(history: history, bands: [(name: "A", rate: { $0 })])
        #expect(abs(bands[0].values[0] - 2.0) < 1e-9)
        #expect(abs(bands[0].values[1] - 1.0) < 1e-9)
    }

    @Test("a tick whose only entries are excluded is dropped entirely, never summed to a fabricated zero")
    func allExcludedTickIsDropped() {
        // Tick 1: only "lo0" reported, and it's excluded — nothing real left
        // to sum. Tick 2: a real device reported.
        let history = Self.stamped([
            ["lo0": 9_000_000],
            ["dev": 1_048_576],
        ])
        let bands = ChartGeometry.throughputBands(
            history: history,
            excluding: ["lo0"],
            bands: [(name: "A", rate: { $0 })]
        )
        // The all-excluded tick must not appear at all — not as a value, and
        // not as a timestamp — rather than surviving as a genuine-looking 0.0.
        #expect(bands[0].values.count == 1)
        #expect(abs(bands[0].values[0] - 1.0) < 1e-9)
        #expect(bands[0].timestamps == [501])
    }

    @Test("a history whose only tick has nothing to sum after exclusion yields no bands at all")
    func allExcludedOnlyTickYieldsNoBands() {
        let history = Self.stamped([
            ["lo0": 9_000_000],
        ])
        let bands = ChartGeometry.throughputBands(
            history: history,
            excluding: ["lo0"],
            bands: [(name: "A", rate: { $0 }), (name: "B", rate: { $0 / 2 })]
        )
        #expect(bands.isEmpty)
    }
}
