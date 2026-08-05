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
    /// actually discriminates — not just that it happens to return `true`
    /// once real data is present (each page's own "renders a full page" test
    /// already checks that), but that it returns `false` when there is
    /// nothing for the chart to draw. A probe that always reported `true`
    /// regardless of input would be exactly as vacuous as the `fileExists`
    /// check it replaced.
    ///
    /// Two representative pages, not all five: a senior review found the
    /// original five-page version made the full suite flaky (6/10 clean
    /// runs, always `MetricsStoreTests.swift`'s `waitUntil`-based tests
    /// timing out). Diagnosed cause — confirmed by reproducing both the
    /// failure and the fix, ten runs each — is that this function has no
    /// `await` anywhere in its body, so once Swift Concurrency schedules it
    /// onto the main actor it runs to completion as one uninterruptible
    /// block: five real `NSWindow`s, each laid out and captured via
    /// `cacheDisplay`, back to back with no suspension point where the
    /// actor could hand off to anything else. A `waitUntil` poll scheduled
    /// on the same main actor at the same time (e.g. `historyIsCapped`'s)
    /// cannot get a turn to check its condition until this function
    /// finishes, and cooperative scheduling being non-preemptive means nine
    /// concurrent renders' worth of wall-clock time can easily exceed
    /// `waitUntil`'s 2-second deadline even though the condition itself was
    /// satisfied almost immediately.
    ///
    /// Rejected fixes: marking this suite `.serialized` only orders this
    /// suite's own two tests relative to each other, not relative to
    /// `MetricsStoreTests` (a different suite, scheduled independently) —
    /// it would not have reduced the actual contention. Raising
    /// `waitUntil`'s timeout instead of shrinking this function would mask
    /// the monopolisation rather than remove it: the block would still run
    /// just as long, only tolerated rather than fixed, and could still lose
    /// on a slower or more loaded machine. CPU and Network were picked to
    /// keep a fraction-unit chart with a secondary component (`CoreGrid`)
    /// and an absolute-unit chart with none, the two structurally different
    /// cases the five pages fall into — cutting to a single page would lose
    /// that coverage rather than just shrinking the uninterruptible block.
    ///
    /// This wave regressed the cut-to-two fix: adding `ChartHeadroomTests`
    /// (pure `ChartGeometry` math, no renders of its own) still pushed the
    /// full suite back to flaky (measured 5/8 and, separately, 5/8 clean
    /// runs — `MetricsStoreTests`' `waitUntil`-based tests timing out,
    /// exactly as before), which means the two-render version of this
    /// function was already sitting right at the edge suspension-wise, not
    /// safely under it — any change that nudges overall scheduling pressure
    /// can tip it back into contention. Rather than cut to one page (losing
    /// the fraction/absolute coverage this test exists to keep) or raise
    /// `waitUntil`'s timeout (masking rather than fixing), this explicitly
    /// yields the main actor between the two renders: `await Task.yield()`
    /// is a real suspension point, so the actor can service a
    /// `waitUntil`-scheduled continuation between the CPU and Network
    /// renders instead of only after both have finished. Confirmed by
    /// running the full suite 16 times after adding the yield: 16/16 clean.
    @Test("an empty store's chart region shows no chart-painted colour, on two representative pages")
    func emptyStoreChartRegionIsUnsaturated() async throws {
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)

        let pages: [(name: String, view: AnyView)] = [
            ("CPU", AnyView(CPUPage(store: store))),
            ("Network", AnyView(NetworkPage(store: store))),
        ]

        for page in pages {
            // The suspension point this function used to lack entirely — see
            // the doc comment above. Yielding before each render (rather than
            // only between them) also gives the actor a chance to run other
            // ready work before the very first of this function's two renders,
            // not just between them.
            await Task.yield()
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
            // 4.0 + 0.5 = 4.5 MB/s. Since the stable-axis change, an
            // absolute-unit chart scales to `ChartGeometry.niceUpperBound`'s
            // rounded ceiling (5, here), not the raw peak, so the topmost
            // band no longer touches the canvas top for an arbitrary reading.
            // 4.5 against 5 is 90% of the chart's height, comfortably inside
            // `chartCanvasProbeRegion`. The previous 2.0/1.0 MB/s fixture
            // (peak 3, bound 5, 60%) sat right at that region's edge and was
            // the actual failure this comment now documents: `#require(try
            // firstSaturatedColor(in: storageRendered, region:
            // chartCanvasProbeRegion))` returned `nil` with that fixture —
            // see `StoragePageTests`' own render test for the matching fix.
            AnySampler { ["disk0": DiskThroughput(bytesReadPerSecond: 4_194_304, bytesWrittenPerSecond: 524_288)] },
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
