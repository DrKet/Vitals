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
