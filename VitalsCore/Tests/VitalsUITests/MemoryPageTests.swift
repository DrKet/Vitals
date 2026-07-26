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
