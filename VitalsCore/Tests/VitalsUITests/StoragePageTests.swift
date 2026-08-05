import MetricsEngine
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

    @Test("a single storage device is named in the vendor-mark slot")
    func singleDeviceIsNamed() {
        let device = StorageDevice(
            name: "APPLE SSD AP0512Z",
            medium: .solidState,
            interconnect: "Apple Fabric",
            revision: "555"
        )
        #expect(StoragePage.vendorName(devices: [device]) == "APPLE SSD AP0512Z")
    }

    @Test("an empty card reader beside one SSD still names the SSD")
    func cardReaderDoesNotBlockSSDName() {
        let ssd = StorageDevice(
            name: "APPLE SSD AP0512Z",
            medium: .solidState,
            interconnect: "Apple Fabric",
            revision: "555"
        )
        let reader = StorageDevice(
            name: "Built In SDXC Reader",
            medium: .unknown,
            interconnect: "Secure Digital",
            revision: nil
        )
        #expect(StoragePage.vendorName(devices: [ssd, reader]) == "APPLE SSD AP0512Z")
    }

    @Test("two stated-media devices withhold the vendor mark rather than picking one")
    func twoStatedMediaWithholdName() {
        let ssd = StorageDevice(
            name: "APPLE SSD AP0512Z",
            medium: .solidState,
            interconnect: "Apple Fabric",
            revision: nil
        )
        let hdd = StorageDevice(
            name: "ST2000DM008-2FR102",
            medium: .rotational,
            interconnect: "SATA",
            revision: nil
        )
        #expect(StoragePage.vendorName(devices: [ssd, hdd]) == nil)
    }

    @Test("no devices yields no vendor mark")
    func noDevicesYieldsNoVendorMark() {
        #expect(StoragePage.vendorName(devices: []) == nil)
    }

    @Test("a device that drops out and returns is summed fresh each tick, never carried forward from an earlier one")
    func deviceDroppingOutAndReturningIsRecomputedEachTick() {
        // Tick 1: disk0 and disk4 both present.
        // Tick 2: disk0 drops out of the dictionary entirely. A per-tick sum
        // over present keys can't distinguish "omitted" from "zero-filled"
        // (both contribute 0 to the total), so this doesn't prove which one
        // happened — only that disk0's prior 1 MB/s reading is not carried
        // forward into this tick's sum.
        // Tick 3: disk0 reappears with a different reading than before it
        // left, proving it is recomputed fresh rather than treated as a
        // delta against its pre-absence value.
        let history = Self.stamped([
            [
                "disk0": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
                "disk4": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
            ],
            [
                "disk4": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
            ],
            [
                "disk0": DiskThroughput(bytesReadPerSecond: 3_145_728, bytesWrittenPerSecond: 0),
                "disk4": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
            ],
        ])
        let series = StoragePage.throughputSeries(history: history)
        let read = series[0].values

        // Tick 1: disk0 (1 MB/s) + disk4 (1 MB/s) = 2 MB/s.
        #expect(abs(read[0] - 2.0) < 1e-9)
        // Tick 2: disk0 is absent from the dictionary, so only disk4's 1 MB/s
        // contributes — disk0's pre-absence 1 MB/s reading is not carried
        // forward into this tick's sum.
        #expect(abs(read[1] - 1.0) < 1e-9)
        // Tick 3: disk0 returns at 3 MB/s (not the 1 MB/s it had before
        // dropping out), so the sum is fresh from this tick's dictionary —
        // 3 MB/s + 1 MB/s = 4 MB/s, not a delta against the earlier reading.
        #expect(abs(read[2] - 4.0) < 1e-9)
    }

    // MARK: totalThroughputSeries (Overview tile)

    @Test("the tile's total series sums Read and Write into a single line, matching the two stacked bands' own sum")
    func totalSeriesSumsReadAndWrite() {
        let history = Self.stamped([
            ["disk0": DiskThroughput(bytesReadPerSecond: 2_097_152, bytesWrittenPerSecond: 1_048_576)]
        ])
        let bands = StoragePage.throughputSeries(history: history)
        let total = StoragePage.totalThroughputSeries(history: history)

        #expect(total.count == 1)
        #expect(abs(total[0].values[0] - (bands[0].values[0] + bands[1].values[0])) < 1e-9)
    }

    @Test("the total series is still summed across every device")
    func totalSeriesSumsAcrossDevices() {
        let history = Self.stamped([[
            "disk0": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0),
            "disk4": DiskThroughput(bytesReadPerSecond: 0, bytesWrittenPerSecond: 1_048_576),
        ]])
        #expect(abs(StoragePage.totalThroughputSeries(history: history)[0].values[0] - 2.0) < 1e-9)
    }

    @Test("a tick with no devices at all is dropped from the total, never summed to a fabricated zero")
    func totalSeriesDropsEmptyTick() {
        let history = Self.stamped([
            [:],
            ["disk0": DiskThroughput(bytesReadPerSecond: 1_048_576, bytesWrittenPerSecond: 0)],
        ])
        let total = StoragePage.totalThroughputSeries(history: history)
        #expect(total[0].values.count == 1)
        #expect(abs(total[0].values[0] - 1.0) < 1e-9)
        #expect(total[0].timestamps == [1001])
    }

    @Test("the total series carries timestamps too")
    func totalSeriesCarriesTimestamps() {
        let history = Self.stamped([
            ["disk0": DiskThroughput(bytesReadPerSecond: 0, bytesWrittenPerSecond: 0)],
            ["disk0": DiskThroughput(bytesReadPerSecond: 0, bytesWrittenPerSecond: 0)],
        ])
        #expect(StoragePage.totalThroughputSeries(history: history)[0].timestamps == [1000, 1001])
    }

    @Test("empty history yields no total series")
    func totalSeriesEmptyHistoryYieldsNoSeries() {
        #expect(StoragePage.totalThroughputSeries(history: []).isEmpty)
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

    /// The whole point of this test: nothing before it ever constructed a
    /// `StoragePage` from a `MetricsStore` and rendered it — every prior test
    /// in this file covers only static, pure helpers (`throughputSeries`) or,
    /// for `VolumeBar` just above, a bare subcomponent.
    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFullPageFromStore() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler {
                [Volume(name: "Macintosh HD", totalBytes: 500_000_000_000, availableBytes: 120_000_000_000, isInternal: true)]
            },
            for: .storage,
            cadence: .fast
        )
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
            // and was intermittently missed depending on rendered height.
            AnySampler { ["disk0": DiskThroughput(bytesReadPerSecond: 4_194_304, bytesWrittenPerSecond: 524_288)] },
            for: .diskIO,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: nil)

        let volumesTask = Task { await store.stream(.storage) }
        let diskIOTask = Task { await store.stream(.diskIO) }
        try await waitUntil { store.volumes != nil && store.diskIOHistory.count >= 2 }
        volumesTask.cancel()
        diskIOTask.cancel()

        let rendered = try renderPNG(
            StoragePage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "storage-page-with-data"
        )
        // See `CPUPageTests.rendersFullPageFromStore` for why `fileExists`
        // alone was vacuous. Throughput is an absolute-unit series; since the
        // stable-axis change it scales to a *rounded* bound
        // (`ChartGeometry.niceUpperBound`), not the raw peak, so the fixture
        // above is chosen to land at 90% of the chart's height rather than
        // exactly 100% — see the comment on the sampler.
        //
        // A plain `regionHasSaturatedColor` is not enough here: `VolumeBar`
        // paints in this page's own lead accent (storage teal, the chart's
        // `colors[0]`), so a broken chart whose collapsed layout slides
        // `VolumeBar` up into this rectangle would still "pass" — the exact
        // false pass a senior review found by hand. Matching only the
        // *other* band's hue (`colors[1]`, i.e. Write) closes that gap: see
        // `regionHasSaturatedColor(in:region:matchingHueOf:)`'s doc comment.
        let series = StoragePage.throughputSeries(history: store.diskIOHistory)
        let nonLeadHues = Array(Vitals.seriesColors(startingAt: Vitals.Palette.storage, count: series.count).dropFirst().map(hue(of:)))
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion, matchingHueOf: nonLeadHues))
    }

    @Test("a freshly constructed page with no samples yet still renders, rather than crashing on nil state")
    func rendersFromEmptyStore() throws {
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(
            StoragePage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "storage-page-empty-store"
        )
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
