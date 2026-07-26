import MetricsEngine
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

/// Render-level guards that span more than one hardware page, so they belong
/// to neither page's own test file.
///
/// Both tests here exist because of gaps a senior review found in the
/// previous fix wave: the five per-page "renders a full page from a live
/// store" tests only ever proved a page painted *something*
/// (`FileManager.fileExists`, which `renderPNG` had already satisfied by the
/// time the assertion ran) — never that the chart's own data-driven drawing
/// was what painted it, and never that a page's chart used its own accent
/// rather than always falling back to CPU blue.
@MainActor
@Suite("Page render regressions")
struct PageRenderRegressionTests {

    /// Confirms `regionHasSaturatedColor` over `chartCanvasProbeRegion`
    /// actually discriminates, across every page — not just that it happens
    /// to return `true` once real data is present (each page's own
    /// "renders a full page" test already checks that), but that it returns
    /// `false` when there is nothing for the chart to draw. A probe that
    /// always reported `true` regardless of input would be exactly as
    /// vacuous as the `fileExists` check it replaced.
    @Test("an empty store's chart region shows no chart-painted colour, on every page")
    func emptyStoreChartRegionIsUnsaturated() throws {
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)

        let pages: [(name: String, view: AnyView)] = [
            ("CPU", AnyView(CPUPage(store: store))),
            ("Memory", AnyView(MemoryPage(store: store))),
            ("GPU", AnyView(GPUPage(store: store))),
            ("Storage", AnyView(StoragePage(store: store))),
            ("Network", AnyView(NetworkPage(store: store))),
        ]

        for page in pages {
            let rendered = try renderPNG(
                page.view,
                size: CGSize(width: 800, height: 700),
                named: "regression-empty-\(page.name.lowercased())"
            )
            #expect(
                try !regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion),
                "\(page.name) page's chart region painted a colour with nothing to chart"
            )
        }
    }

    /// Fix 3: each hardware page leads its chart's colour ramp with its own
    /// accent (`HardwarePage`'s `accent:` parameter, wired through to
    /// `Vitals.seriesColors(startingAt:count:)`), fixing charts that used to
    /// render in CPU blue regardless of the page. Existing coverage
    /// (`TokensTests` on `Vitals.seriesColors` in isolation,
    /// `HardwarePageTests` on the parameter pass-through) never renders a
    /// page and looks at what actually painted — nothing would notice if a
    /// page's `accent` stopped reaching its `MetricChart`. This samples the
    /// rendered bitmaps of two different pages in the same probe region and
    /// checks the colours actually differ.
    @Test("two different pages' charts actually paint different colours")
    func differentPagesPaintDifferentChartColours() async throws {
        // GPU and Storage, specifically: both chart exactly two stacked
        // bands (Renderer/Tiler, Read/Write), so under the regression this
        // guards against — every page falling back to
        // `Vitals.seriesColors(count:)`'s unrotated default ramp instead of
        // its own accent-led one — both pages would independently compute
        // the *identical* two-colour sequence `[cpu, storage]` and paint
        // indistinguishably. A CPU/Memory pairing would not actually catch
        // that regression: CPU's own accent already happens to be the ramp's
        // default start, so its chart looks the same whether or not
        // `accent` reaches it, and Memory would still land on a different
        // (if wrong) colour by coincidence. Verified by hand: temporarily
        // reverting `HardwarePage.swift`'s `colors:` argument to
        // `Vitals.seriesColors(count:)` makes this test fail, while a
        // CPU/Memory version of it still passed.
        let profile = try HardwareProfile.detect()

        let gpuEngine = MetricsEngine(intervalOverride: .milliseconds(5))
        await gpuEngine.register(
            AnySampler {
                // Renderer + Tiler sums to 0.9 — see `chartCanvasProbeRegion`'s
                // doc comment for why that keeps the topmost band's curve near
                // the canvas top regardless of the chart's actual height.
                [GPUSample(
                    deviceUtilisation: 0.6, rendererUtilisation: 0.5, tilerUtilisation: 0.4,
                    inUseMemoryBytes: 2_000_000_000, allocatedMemoryBytes: 4_000_000_000
                )]
            },
            for: .gpu,
            cadence: .fast
        )
        let gpuStore = MetricsStore(engine: gpuEngine, profile: profile)
        let gpuTask = Task { await gpuStore.stream(.gpu) }
        try await waitUntil { gpuStore.gpuHistory.count >= 2 }
        gpuTask.cancel()
        let gpuRendered = try renderPNG(
            GPUPage(store: gpuStore), size: CGSize(width: 800, height: 700), named: "regression-colour-gpu"
        )

        let storageEngine = MetricsEngine(intervalOverride: .milliseconds(5))
        await storageEngine.register(
            AnySampler {
                [Volume(
                    name: "Macintosh HD", totalBytes: 500_000_000_000,
                    availableBytes: 120_000_000_000, isInternal: true
                )]
            },
            for: .storage,
            cadence: .fast
        )
        await storageEngine.register(
            // Absolute-unit throughput auto-scales to its own peak, so any
            // non-zero reading already touches the canvas top — no tuning
            // needed, as in `StoragePageTests`'s own render test.
            AnySampler { ["disk0": DiskThroughput(bytesReadPerSecond: 2_097_152, bytesWrittenPerSecond: 1_048_576)] },
            for: .diskIO,
            cadence: .fast
        )
        let storageStore = MetricsStore(engine: storageEngine, profile: profile)
        let storageTask = Task { await storageStore.stream(.storage) }
        let diskIOTask = Task { await storageStore.stream(.diskIO) }
        try await waitUntil { storageStore.diskIOHistory.count >= 2 }
        storageTask.cancel()
        diskIOTask.cancel()
        let storageRendered = try renderPNG(
            StoragePage(store: storageStore), size: CGSize(width: 800, height: 700), named: "regression-colour-storage"
        )

        let gpuColor = try #require(try firstSaturatedColor(in: gpuRendered, region: chartCanvasProbeRegion))
        let storageColor = try #require(try firstSaturatedColor(in: storageRendered, region: chartCanvasProbeRegion))

        // Compares hue, not raw RGB distance. The area fill's gradient blends
        // the band's colour toward the (neutral grey) material behind it at
        // whatever alpha corresponds to a given pixel's height in the chart,
        // and GPU's and Storage's topmost bands sit at slightly different
        // heights (a fraction-unit series clamped near, but not at, the
        // chart's upper bound vs. an absolute-unit series that always touches
        // it exactly) — so the two pages' *actual, correctly-differing* hues
        // can still land at slightly different brightness/saturation, which
        // a raw RGB distance would conflate with a genuine hue difference.
        // Blending a saturated colour toward a neutral grey preserves hue
        // angle exactly (the RGB channel differences that determine it all
        // scale by the same alpha), so hue is the alpha-invariant thing to
        // compare. Verified by hand against the regression this guards:
        // reverting `HardwarePage.swift` to the unrotated default ramp made
        // GPU and Storage sample hues 0.0038 apart (identical, both landing
        // on the ramp's `storage` slot); correct behaviour puts them roughly
        // 0.59 apart on the hue wheel.
        var gpuHue: CGFloat = 0, gpuSaturation: CGFloat = 0, gpuBrightness: CGFloat = 0, gpuAlpha: CGFloat = 0
        gpuColor.getHue(&gpuHue, saturation: &gpuSaturation, brightness: &gpuBrightness, alpha: &gpuAlpha)
        var storageHue: CGFloat = 0, storageSaturation: CGFloat = 0, storageBrightness: CGFloat = 0, storageAlpha: CGFloat = 0
        storageColor.getHue(&storageHue, saturation: &storageSaturation, brightness: &storageBrightness, alpha: &storageAlpha)

        // Hue is circular (0 and 1 are the same angle), so the true angular
        // gap is the smaller of the raw difference and its wraparound.
        let rawGap = abs(gpuHue - storageHue)
        let hueGap = min(rawGap, 1 - rawGap)
        #expect(
            hueGap > 0.1,
            "GPU (hue \(gpuHue)) and Storage (hue \(storageHue)) charts painted indistinguishable colours"
        )
    }
}
