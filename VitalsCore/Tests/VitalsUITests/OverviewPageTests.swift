import Foundation
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Overview page")
struct OverviewPageTests {

    private static let sample = GPUSample(
        deviceUtilisation: 0.42,
        rendererUtilisation: 0.3,
        tilerUtilisation: 0.1,
        inUseMemoryBytes: 1_000,
        allocatedMemoryBytes: 2_000
    )

    @Test("a single-GPU reading formats as a percentage on the tile")
    func singleGPUFormatsAsPercentage() {
        #expect(OverviewPage.gpuTileValue(sample: Self.sample, gpuCount: 1, sampleCount: 1) == "42%")
    }

    @Test("multi-GPU attribution withholds the tile value, matching GPUPage")
    func multiGPUWithholdsTileValue() {
        // The Overview must apply the same gate as the detail page — showing
        // one GPU's utilisation under a generic "GPU" label on a multi-GPU
        // Mac would attribute a real measurement to the wrong hardware.
        #expect(OverviewPage.gpuTileValue(sample: Self.sample, gpuCount: 2, sampleCount: 1) == nil)
        #expect(OverviewPage.gpuTileValue(sample: Self.sample, gpuCount: 1, sampleCount: 2) == nil)
    }

    @Test("an absent device utilisation stays nil on the tile, never a fabricated zero")
    func absentDeviceUtilisationStaysNil() {
        let blank = GPUSample(
            deviceUtilisation: nil,
            rendererUtilisation: 0.3,
            tilerUtilisation: 0.1,
            inUseMemoryBytes: nil,
            allocatedMemoryBytes: nil
        )
        #expect(OverviewPage.gpuTileValue(sample: blank, gpuCount: 1, sampleCount: 1) == nil)
        #expect(OverviewPage.gpuTileValue(sample: nil, gpuCount: 1, sampleCount: 1) == nil)
    }

    @Test("an lo0-only tick withholds the Network tile, matching NetworkPage")
    func lo0OnlyWithholdsNetworkTile() {
        let lo0Only = ["lo0": NetworkThroughput(bytesInPerSecond: 9_000_000, bytesOutPerSecond: 9_000_000)]
        #expect(OverviewPage.networkTileValue(lo0Only) == nil)
        #expect(OverviewPage.networkTileValue(nil) == nil)
    }

    @Test("a real interface's total throughput formats on the Network tile")
    func realInterfaceFormatsOnNetworkTile() {
        let active = ["en0": NetworkThroughput(bytesInPerSecond: 1_048_576, bytesOutPerSecond: 1_048_576)]
        #expect(OverviewPage.networkTileValue(active) == "2.00 MB/s")
    }

    @Test("Storage tile primary matches StoragePage's own total")
    func storageTileMatchesPagePrimary() {
        let diskIO = ["disk0": DiskThroughput(bytesReadPerSecond: 2_097_152, bytesWrittenPerSecond: 1_048_576)]
        #expect(StoragePage.primaryValue(diskIO) == "3.00 MB/s")
        #expect(StoragePage.primaryValue(nil) == nil)
    }

    // MARK: Tile charts — one line per tile, matching its own headline number

    private static func gpuHistory(_ samples: [GPUSample]) -> [Timestamped<[GPUSample]>] {
        samples.enumerated().map { Timestamped(timestamp: 1000 + TimeInterval($0.offset), sample: [$0.element]) }
    }

    @Test("the GPU tile chart is a single device-utilisation line, never Renderer+Tiler summed")
    func gpuTileSeriesIsDeviceUtilisationNotEngineSum() {
        // Renderer 0.3 + Tiler 0.2 = 0.5, deliberately different from
        // deviceUtilisation's 0.72: routing the tile through `engineSeries`
        // summed (the exact regression this rule forbids) would land on 0.5,
        // not 0.72.
        let sample = GPUSample(
            deviceUtilisation: 0.72, rendererUtilisation: 0.3, tilerUtilisation: 0.2,
            inUseMemoryBytes: nil, allocatedMemoryBytes: nil
        )
        let series = OverviewPage.gpuTileSeries(history: Self.gpuHistory([sample]), gpuCount: 1, sampleCount: 1)

        #expect(series.count == 1)
        #expect(abs(series[0].values[0] - 0.72) < 1e-9)
    }

    @Test("a GPU tick missing device utilisation withholds the whole tile series, not a short one")
    func gpuTileSeriesIsAllOrNothing() {
        let history: [Timestamped<[GPUSample]>] = [
            Timestamped(
                timestamp: 1000,
                sample: [GPUSample(
                    deviceUtilisation: 0.5, rendererUtilisation: 0.3, tilerUtilisation: 0.2,
                    inUseMemoryBytes: nil, allocatedMemoryBytes: nil
                )]
            ),
            Timestamped(
                timestamp: 1001,
                sample: [GPUSample(
                    deviceUtilisation: nil, rendererUtilisation: 0.4, tilerUtilisation: 0.1,
                    inUseMemoryBytes: nil, allocatedMemoryBytes: nil
                )]
            ),
        ]
        #expect(OverviewPage.gpuTileSeries(history: history, gpuCount: 1, sampleCount: 1).isEmpty)
    }

    @Test("multi-GPU attribution suppresses the tile's chart too, matching the tile's value")
    func gpuTileSeriesWithheldOnMultiGPU() {
        let series = OverviewPage.gpuTileSeries(history: Self.gpuHistory([Self.sample]), gpuCount: 2, sampleCount: 1)
        #expect(series.isEmpty)
        // The mirror case (fewer named GPUs than IOAccelerator samples this
        // tick) is exactly as ambiguous — see `GPUPage.isMultiGPU`'s doc
        // comment — and must withhold the tile's chart too.
        #expect(OverviewPage.gpuTileSeries(history: Self.gpuHistory([Self.sample]), gpuCount: 1, sampleCount: 2).isEmpty)
    }

    @Test("the Storage tile chart sums Read and Write into a single line, routed through StoragePage's total")
    func storageTileSeriesSumsBands() {
        let history: [Timestamped<[String: DiskThroughput]>] = [
            Timestamped(
                timestamp: 1000,
                sample: ["disk0": DiskThroughput(bytesReadPerSecond: 2_097_152, bytesWrittenPerSecond: 1_048_576)]
            )
        ]
        let bands = StoragePage.throughputSeries(history: history)
        let series = OverviewPage.storageTileSeries(history: history)

        #expect(series.count == 1)
        #expect(abs(series[0].values[0] - (bands[0].values[0] + bands[1].values[0])) < 1e-9)
    }

    @Test("the Network tile chart sums Down and Up into a single line, routed through NetworkPage's total")
    func networkTileSeriesSumsBands() {
        let history: [Timestamped<[String: NetworkThroughput]>] = [
            Timestamped(
                timestamp: 1000,
                sample: ["en0": NetworkThroughput(bytesInPerSecond: 2_097_152, bytesOutPerSecond: 1_048_576)]
            )
        ]
        let bands = NetworkPage.throughputSeries(history: history)
        let series = OverviewPage.networkTileSeries(history: history)

        #expect(series.count == 1)
        #expect(abs(series[0].values[0] - (bands[0].values[0] + bands[1].values[0])) < 1e-9)
    }
}
