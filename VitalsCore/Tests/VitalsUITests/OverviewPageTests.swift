import Foundation
import MetricsEngine
import SwiftUI
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

    // MARK: Render (axis-maximum suppression)

    /// The whole point of this test: nothing before it ever constructed an
    /// `OverviewPage` from a live store and rendered it — every prior test in
    /// this file covers only pure helpers. That gap is exactly why the bug
    /// this guards against shipped unnoticed: `MetricChart`'s axis-maximum
    /// label (added for the hardware pages, see `ChartGeometry.axisMaximum`)
    /// was silently inherited by `MetricTile` too, so the Storage and Network
    /// tiles briefly showed their throughput twice — once as the tile's own
    /// 22pt headline, once again as an 11pt ceiling directly beneath it.
    ///
    /// Storage and Network are the only tiles that can carry the label at
    /// all — CPU, Memory and GPU are `.fraction`-unit series, which
    /// `ChartGeometry.axisMaximum` always returns `nil` for regardless of
    /// this flag (see its doc comment) — so they are not probed here.
    @Test("the axis-maximum label never reaches the Storage or Network tile, whose headline already states it")
    func storageAndNetworkTilesSuppressTheAxisMaximumLabel() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            // 4.0 + 0.5 = 4.5 MB/s, deliberately not a "nice" bound itself —
            // see `StoragePageTests.rendersFullPageFromStore`'s sampler
            // comment. `ChartGeometry.niceUpperBound` rounds this up to a
            // labelled 5 MB/s ceiling, which is exactly the reading that must
            // not reach the tile.
            AnySampler { ["disk0": DiskThroughput(bytesReadPerSecond: 4_194_304, bytesWrittenPerSecond: 524_288)] },
            for: .diskIO,
            cadence: .fast
        )
        await engine.register(
            AnySampler { ["en0": NetworkThroughput(bytesInPerSecond: 4_194_304, bytesOutPerSecond: 524_288)] },
            for: .network,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: nil)

        let diskIOTask = Task { await store.stream(.diskIO) }
        let networkTask = Task { await store.stream(.network) }
        try await waitUntil { store.diskIOHistory.count >= 2 && store.networkHistory.count >= 2 }
        diskIOTask.cancel()
        networkTask.cancel()

        let rendered = try renderPNG(
            OverviewPage(store: store),
            size: CGSize(width: 900, height: 700),
            named: "overview-page-with-data"
        )

        // Both rectangles are derived from this exact render, not guessed:
        // diffing this fixture's output against a build with `MetricTile`'s
        // `showsAxisMaximum` forced to `true` (see `MetricChart.init`'s doc
        // comment for why that flag exists) isolated the label to
        // x:[24.5, 60.0], y:[437.5, 447.5] pt on the Storage tile and
        // x:[328.5, 364.0], y:[437.5, 447.5] pt on the Network tile — nowhere
        // else in the image changed. These rectangles pad that measured
        // bounding box on every side; the nearest real content in either
        // direction is the tile's own headline well above y=420 and the
        // chart's flat throughput line starting at y=457 (confirmed by
        // scanning the same column), so there is no dimension in which
        // widening the pad here could accidentally catch something else.
        //
        // `regionHasContent(in:region:)` cannot be used for this: it compares
        // against the image's own top-left corner, which sits outside every
        // `GlassPanel` and so differs from a panel's opaque material
        // regardless of what is drawn inside it — see
        // `regionHasSaturatedColor`'s doc comment for the same problem from
        // the saturation angle, and
        // `regionHasContent(in:region:differingFrom:)`'s doc comment for why
        // that check cannot help either (the label is neutral grey, with
        // nothing for a saturation probe to find). Comparing against the
        // material's own known fallback colour is what actually isolates the
        // label.
        let storageLabelRegion = CGRect(x: 18, y: 433, width: 50, height: 18)
        let networkLabelRegion = CGRect(x: 322, y: 433, width: 50, height: 18)

        #expect(try !regionHasContent(in: rendered, region: storageLabelRegion, differingFrom: glassPanelMaterialFallback))
        #expect(try !regionHasContent(in: rendered, region: networkLabelRegion, differingFrom: glassPanelMaterialFallback))
    }
}
