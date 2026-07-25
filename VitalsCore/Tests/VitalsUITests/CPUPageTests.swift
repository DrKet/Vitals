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
        // L3 genuinely does not exist on Apple Silicon. `formatCache` hands
        // back `nil` — not the baked-in string "Unavailable" — so `StatRow`
        // is the single place that decides how absence is worded and styled.
        #expect(CPUPage.formatCache(nil) == nil)
        #expect(CPUPage.formatCache(4_194_304)?.contains("4") == true)
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
        let history = [
            CPULoadSample(cores: (0..<6).map { _ in CoreLoad(user: 0.5, system: 0, idle: 0.5, nice: 0) })
        ]
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
}
