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
}
