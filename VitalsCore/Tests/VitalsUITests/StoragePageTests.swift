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
        // Byte-to-MB/s division is floating point, so compare with tolerance
        // rather than `==` — see `CPUPageTests.intelFallsBackToTotal` for the
        // same pattern.
        #expect(abs(series[0].values[0] - 2.0) < 1e-9)
        #expect(abs(series[1].values[0] - 1.0) < 1e-9)
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
        #expect(abs(StoragePage.throughputSeries(history: history)[0].values[0] - 2.0) < 1e-9)
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
        let rendered = try renderPNG(bar, size: CGSize(width: 400, height: 60), named: "volume-bar")
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
