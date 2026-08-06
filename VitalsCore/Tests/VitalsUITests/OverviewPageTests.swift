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

    // MARK: Tile fractions — the proportion bar's value, gated exactly like the tile

    @Test("the GPU tile fraction is the attributable device utilisation, or nil")
    func gpuTileFractionMirrorsTheValueGate() {
        // Same gate as gpuTileValue: a single attributable GPU yields its raw
        // device utilisation (0.42), and every ambiguous case yields nil so the
        // bar is absent exactly when the value is.
        #expect(OverviewPage.gpuTileFraction(sample: Self.sample, gpuCount: 1, sampleCount: 1)
                .map { abs($0 - 0.42) < 1e-9 } == true)
        #expect(OverviewPage.gpuTileFraction(sample: Self.sample, gpuCount: 2, sampleCount: 1) == nil)
        #expect(OverviewPage.gpuTileFraction(sample: Self.sample, gpuCount: 1, sampleCount: 2) == nil)
        #expect(OverviewPage.gpuTileFraction(sample: nil, gpuCount: 1, sampleCount: 1) == nil)
    }

    @Test("the memory fraction guards a missing or zero total, never dividing by zero")
    func memoryFractionGuardsTheTotal() {
        #expect(OverviewPage.memoryFraction(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
                .map { abs($0 - 0.5) < 1e-9 } == true)
        // A total the machine could not report is not a whole to be a fraction of.
        #expect(OverviewPage.memoryFraction(usedBytes: 8_000_000_000, totalBytes: nil) == nil)
        #expect(OverviewPage.memoryFraction(usedBytes: 8_000_000_000, totalBytes: 0) == nil)
        // No used reading yet is likewise nil, not a fabricated zero.
        #expect(OverviewPage.memoryFraction(usedBytes: nil, totalBytes: 16_000_000_000) == nil)
    }

    @Test("Battery is a tile only on a machine that has one")
    func batteryTileIsConditional() {
        let withBattery = OverviewPage.tileOrder(hasBattery: true)
        let without = OverviewPage.tileOrder(hasBattery: false)
        #expect(withBattery.contains("battery"))
        #expect(withBattery.count == 6)
        #expect(without.contains("battery") == false)
        #expect(without.count == 5)
        // The five base tiles keep their established order in both cases.
        #expect(Array(withBattery.prefix(5)) == ["cpu", "memory", "gpu", "storage", "network"])
        #expect(without == ["cpu", "memory", "gpu", "storage", "network"])
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
            size: CGSize(width: 1320, height: 760),
            named: "overview-page-with-data"
        )

        // Both rectangles are derived from this exact render, not guessed:
        // with `MetricTile`'s `showsAxisMaximum` temporarily forced to `true`
        // (see `MetricChart.init`'s doc comment for why that flag exists) the
        // label appears at the throughput tiles' chart top-leading corner, and
        // these padded rectangles sit on it — verified both ways: forcing the
        // flag on makes both `#expect`s below fail (the probe genuinely finds
        // the label), and the production `false` passes (it is absent). The
        // label sits around y≈466 on both the Storage and Network tiles at
        // this render.
        //
        // The `y` moved down from a previous 429 when `overviewTileMaxHeight`
        // went 340 → 520: at this 1320×760 render the two rows are no longer
        // capped (each is (760−12)/2 = 374pt, under the ceiling), so row two
        // starts 34pt lower than it did when the 340 cap held it to 340.
        // Columns are unchanged — `minimumTileWidth` 420 → 340 still yields
        // three columns at 1320 wide — so the `x` values are unchanged. The
        // rectangles pad the measured box on every side; the nearest real
        // content is the tile's own value text above and the chart fill below,
        // so widening the pad cannot catch something else.
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
        let storageLabelRegion = CGRect(x: 18, y: 463, width: 50, height: 18)
        let networkLabelRegion = CGRect(x: 462, y: 463, width: 50, height: 18)

        #expect(try !regionHasContent(in: rendered, region: storageLabelRegion, differingFrom: glassPanelMaterialFallback))
        #expect(try !regionHasContent(in: rendered, region: networkLabelRegion, differingFrom: glassPanelMaterialFallback))
    }
}
