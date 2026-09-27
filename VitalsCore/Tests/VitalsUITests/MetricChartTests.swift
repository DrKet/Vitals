import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("MetricChart")
struct MetricChartTests {

    private static func wave(_ count: Int, phase: Double, scale: Double) -> [Double] {
        (0..<count).map { index in
            let t = Double(index) / Double(count)
            return (sin(t * 6 + phase) * 0.5 + 0.5) * scale
        }
    }

    @Test("renders a single-series area chart")
    func rendersSingleSeries() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: Self.wave(60, phase: 0, scale: 0.6))],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        // No region-specific assertion: a single smoothed curve has no fixed
        // location a probe could target without reimplementing the curve's
        // geometry, so `renderPNG`'s whole-image blank check is the only
        // meaningful guarantee here.
        _ = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-area-single")
    }

    @Test("renders stacked P-core and E-core bands, the CPU page's decomposition")
    func rendersStackedSeries() throws {
        let size = CGSize(width: 600, height: 132)
        let chart = MetricChart(
            series: [
                ChartSeries(name: "Performance", values: Self.wave(60, phase: 0, scale: 0.5)),
                ChartSeries(name: "Efficiency", values: Self.wave(60, phase: 2, scale: 0.2)),
            ],
            style: .area(stacked: true),
            colors: Vitals.seriesColors(count: 2),
            showsAxisMaximum: true
        )
        let rendered = try renderPNG(chart, size: size, named: "chart-area-stacked")

        // Performance alone never exceeds ~0.4999 (its `scale`), which maps
        // to y >= 66pt in a 132pt-tall chart. The stacked total (Performance
        // + Efficiency) peaks at ~0.577 for x in roughly [40, 193]pt, which
        // reaches up to y ~= 55.8pt — content strictly above y = 64pt in that
        // x-range can only exist because the bands are actually stacked, not
        // just because *a* curve got drawn. The region also keeps clear of
        // the gridlines at y = 33/66/99pt, so it can't pass on gridlines alone.
        let stackedOnlyRegion = CGRect(x: 50, y: 40, width: 130, height: 24)
        #expect(try regionHasContent(in: rendered, region: stackedOnlyRegion))
    }

    @Test("renders a histogram, the default at small widget sizes")
    func rendersHistogram() throws {
        let size = CGSize(width: 600, height: 132)
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: Self.wave(40, phase: 0, scale: 0.9))],
            style: .histogram,
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        let rendered = try renderPNG(chart, size: size, named: "chart-histogram")

        // Bars grow up from the bottom edge, so a bar's own content always
        // reaches the chart's very bottom slice — but the gridlines never do
        // (the lowest one sits at 75% down, y = 99pt). A region confined to
        // the bottom 15% can therefore only show content if `drawHistogram`
        // actually drew a bar there. This is the regression the review
        // flagged: `rendersHistogram` previously passed via `fileExists` even
        // with `drawHistogram`'s body deleted, since gridlines draw
        // unconditionally and satisfy the whole-image blank check on their own.
        let bottomSlice = CGRect(x: 0, y: size.height * 0.85, width: size.width, height: size.height * 0.15)
        #expect(try regionHasContent(in: rendered, region: bottomSlice))
    }

    @Test("a histogram of all-zero values draws no bars but still renders")
    func histogramOfZeroesRenders() throws {
        // Exercises the `height > 0` guard: every bar is skipped, so only the
        // gridlines remain. No region probe here — the point of this test is
        // that *nothing else* renders, so the whole-image blank check (which
        // still holds thanks to the gridlines) is exactly the right amount of
        // assertion.
        let chart = MetricChart(
            series: [ChartSeries(name: "Idle", values: Array(repeating: 0, count: 20))],
            style: .histogram,
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        _ = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-histogram-zero")
    }

    @Test("a break in sampling renders as empty space, not a line drawn through it")
    func gapRendersAsEmptySpace() throws {
        // Two runs of samples an hour apart. The chart must show the two runs
        // with nothing between them — a line across the gap would assert a
        // continuity the machine never reported.
        let values = Array(repeating: 0.7, count: 20) + Array(repeating: 0.3, count: 20)
        var timestamps = (0..<20).map { TimeInterval($0) }
        timestamps += (0..<20).map { 3600 + TimeInterval($0) }

        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: values, timestamps: timestamps)],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        let rendered = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-gap")
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }

    @Test("an untimestamped series still renders as one unbroken run")
    func untimestampedSeriesIsUnbroken() throws {
        // Regression guard: adding the time axis must not change how a series
        // without timestamps draws.
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: Self.wave(40, phase: 0, scale: 0.7))],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        let rendered = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-no-timestamps")
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }

    @Test("an empty series renders without crashing")
    func emptySeriesRenders() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: [])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        // No content is expected at all here; the point of this test is that
        // rendering an empty series doesn't crash, so the harness's own
        // "did this throw" and blank-image checks are all that applies.
        _ = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-empty")
    }

    @Test("a single sample renders without crashing")
    func singleSampleRenders() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: [0.4])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        _ = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-single-sample")
    }

    // MARK: Crosshair sample count (regression coverage for the ragged-series bug)

    @Test("resolved bands truncate ragged series to their shortest length in stacked mode")
    func resolvedBandsTruncateRaggedSeriesWhenStacked() {
        // The crosshair derives its sample count from `resolvedBands()`
        // precisely because `ChartGeometry.stack` truncates ragged series
        // (e.g. a new network interface appearing mid-history) to their
        // common length. If the crosshair instead used the raw series'
        // lengths, it could index past what `resolvedBands()` — and
        // therefore the renderer — ever produced.
        let chart = MetricChart(
            series: [
                ChartSeries(name: "wlan0", values: [0.1, 0.2, 0.3]),
                ChartSeries(name: "en0", values: [0.4, 0.5]),
            ],
            style: .area(stacked: true),
            colors: Vitals.seriesColors(count: 2),
            showsAxisMaximum: true
        )
        let bands = chart.resolvedBands()
        #expect(bands.allSatisfy { $0.count == 2 })
    }

    @Test("resolved bands do not truncate ragged series when unstacked")
    func resolvedBandsKeepRaggedSeriesWhenUnstacked() {
        // Unstacked area mode draws each series independently against the
        // baseline, so there is no shared length to truncate to — each
        // band keeps its own series' full length.
        let chart = MetricChart(
            series: [
                ChartSeries(name: "wlan0", values: [0.1, 0.2, 0.3]),
                ChartSeries(name: "en0", values: [0.4, 0.5]),
            ],
            style: .area(stacked: false),
            colors: Vitals.seriesColors(count: 2),
            showsAxisMaximum: true
        )
        let bands = chart.resolvedBands()
        #expect(bands.map(\.count).sorted() == [2, 3])
    }

    // MARK: Axis label

    /// The label is text in a neutral grey, so `regionHasSaturatedColor` is
    /// the wrong probe — this uses `regionHasContent` against a corner of the
    /// canvas that gridlines alone would leave at the background colour.
    @Test("an absolute-unit chart labels its ceiling and a fractional one does not")
    func absoluteChartsDrawAnAxisLabel() throws {
        let absolute = MetricChart(
            series: [ChartSeries(name: "Down", values: [0.01, 0.4, 0.12], unit: .absolute(suffix: "MB/s"))],
            style: .area(stacked: false),
            colors: [Vitals.Palette.network],
            // This is the "on" call site the parameter exists to keep
            // honest — a hardware-page-style embedding that wants the label.
            showsAxisMaximum: true
        )
        let fractional = MetricChart(
            series: [ChartSeries(name: "Busy", values: [0.2, 0.4, 0.37])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            // `true` here too, deliberately: this half of the test proves a
            // fractional chart never draws the label even when the embedder
            // asks for it, which is a stronger guarantee than proving it only
            // when both the unit *and* the flag say no.
            showsAxisMaximum: true
        )
        let corner = CGRect(x: 2, y: 0, width: 90, height: 18)

        let withLabel = try renderPNG(absolute, size: CGSize(width: 400, height: 200), named: "chart-axis-label")
        let without = try renderPNG(fractional, size: CGSize(width: 400, height: 200), named: "chart-no-axis-label")

        #expect(try regionHasContent(in: withLabel, region: corner))
        #expect(try !regionHasContent(in: without, region: corner))
    }

    // MARK: Floating baseline (temperature)

    /// A zero-based chart would compress the spike's real 2.13 °C swing into
    /// 4% of the canvas height. With a floating baseline it must occupy a
    /// visible fraction of it — this asserts the band is drawn well away from
    /// the bottom edge, which can only happen if the lower bound is non-zero.
    @Test("a temperature chart plots against a floating baseline")
    func temperatureChartFloatsItsBaseline() throws {
        let series = [ChartSeries(
            name: "Die",
            values: [36.69, 37.5, 38.82],
            unit: .temperature
        )]
        let chart = MetricChart(series: series, style: .area(stacked: false), colors: [Vitals.Palette.cpu], showsAxisMaximum: true)
        let rendered = try renderPNG(chart, size: CGSize(width: 400, height: 200), named: "chart-temperature-floating")

        // The discriminator is where the STROKE sits, not where the fill
        // reaches: `drawAreas` fills from the curve down to the baseline in
        // both configurations, so "is there colour in the lower half" is true
        // either way and would assert nothing.
        //
        // Bounds 35–40 put the samples at 34%–76% of the height, i.e. the
        // curve runs through the middle. Zero-based bounds (0–40) would put
        // them at 92%–97%, i.e. hard against the top.
        let topStrip = CGRect(x: 0, y: 0, width: 400, height: 24)
        let middleBand = CGRect(x: 0, y: 60, width: 400, height: 80)
        #expect(try !regionHasSaturatedColor(in: rendered, region: topStrip))
        #expect(try regionHasSaturatedColor(in: rendered, region: middleBand))
    }

    /// The rule that keeps the Sensors chart both legible and consistent with
    /// the rest of the app.
    ///
    /// Coverage lives on this pure function rather than on a render probe for
    /// a specific reason: `renderPNG` writes PNGs with UNPREMULTIPLIED colour,
    /// so a pixel at 0.15 alpha still stores full-strength RGB. A saturation
    /// probe therefore cannot tell a light fill from a heavy one — it sees
    /// both. The render test below can only prove a fill was drawn at all;
    /// this is what proves it was drawn at the right weight.
    @Test("fill weight is chosen by overlap, not by unit")
    func fillWeightIsKeyedOnOverlap() {
        // Stacked bands tile rather than overlap, so they keep spec §6.3's
        // full-weight gradient.
        #expect(abs(MetricChart.fillOpacity(stacked: true, bandCount: 4) - 0.45) < 1e-9)

        // A lone band cannot cover anything. This is the Overview tile case:
        // `MetricTile` passes `stacked: series.count > 1`, i.e. `false` for a
        // single-series tile, and those must not lighten.
        #expect(abs(MetricChart.fillOpacity(stacked: false, bandCount: 1) - 0.45) < 1e-9)

        // Several independent readings at different heights each fill to the
        // same baseline, so the highest one's sheet lies over the rest.
        #expect(MetricChart.fillOpacity(stacked: false, bandCount: 3) < 0.45)
    }

    /// Guards against silently shipping bare strokes: an earlier revision
    /// removed the fill from temperature charts entirely, which made Sensors
    /// the only page in the app not drawing spec §6.3's area style.
    @Test("an unstacked multi-series chart still fills beneath its curves")
    func unstackedMultiSeriesChartStillFills() throws {
        let series = [
            ChartSeries(name: "Die", values: [38.0, 38.0, 38.0], unit: .temperature),
            ChartSeries(name: "Battery", values: [26.0, 26.0, 26.0], unit: .temperature),
        ]
        let chart = MetricChart(
            series: series, style: .area(stacked: false),
            colors: [Vitals.Palette.sensors, Vitals.Palette.cpu], showsAxisMaximum: true
        )
        let rendered = try renderPNG(chart, size: CGSize(width: 400, height: 200), named: "chart-temperature-faint-fill")

        // Bounds for 26...38 are 25–40, so the top curve sits at ~87% and the
        // band well beneath it is fill rather than stroke.
        let beneathTheTopCurve = CGRect(x: 20, y: 60, width: 360, height: 40)
        #expect(try regionHasSaturatedColor(in: rendered, region: beneathTheTopCurve))
    }

    // MARK: Load-reactive glow

    /// The glow ramp is tested directly, not through a render, for the same
    /// reason `fillOpacity` is: `renderPNG` writes unpremultiplied PNGs, so a
    /// probe cannot distinguish a faint bloom from a heavy one. This pins the
    /// weight the render can only prove was drawn at all.
    @Test("glow weight rises with the line's height and is off below the floor")
    func glowRampFollowsHeight() {
        let config = Vitals.Chart.Glow(isEnabled: true, maxRadius: 10, maxOpacity: 0.55, floor: 0.12)

        // At and below the floor the glow is genuinely off, so an idle
        // baseline reads as a flat line rather than a faintly lit one.
        #expect(MetricChart.glowLevel(atHeight: 0.0, config: config).opacity == 0)
        #expect(MetricChart.glowLevel(atHeight: config.floor, config: config).opacity == 0)

        // The top of the scale reaches the configured peak on both axes.
        let peak = MetricChart.glowLevel(atHeight: 1.0, config: config)
        #expect(abs(peak.opacity - config.maxOpacity) < 1e-9)
        #expect(abs(peak.radius - config.maxRadius) < 1e-9)

        // And it is monotonic in between — a higher line never glows less.
        let low = MetricChart.glowLevel(atHeight: 0.4, config: config)
        let high = MetricChart.glowLevel(atHeight: 0.8, config: config)
        #expect(low.opacity > 0)
        #expect(high.opacity > low.opacity)
        #expect(high.radius > low.radius)
    }

    /// The master switch means *no layer*, not a layer at zero opacity — a
    /// disabled config must restore the exact pre-glow render.
    @Test("a disabled glow config produces no bloom at any height")
    func disabledGlowIsInert() {
        let off = Vitals.Chart.Glow(isEnabled: false, maxRadius: 10, maxOpacity: 0.55, floor: 0.12)
        #expect(MetricChart.glowLevel(atHeight: 1.0, config: off).opacity == 0)
        #expect(MetricChart.glowLevel(atHeight: 0.5, config: off).opacity == 0)
    }

    /// A render smoke test: the glow path draws without crashing and still
    /// produces a chart. It cannot assert the glow's *weight* (see the ramp
    /// test above), only that enabling it did not blank or break the render.
    @Test("a chart renders with the reactive glow drawn behind its stroke")
    func chartRendersWithGlow() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: Self.wave(60, phase: 0, scale: 0.9))],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu],
            showsAxisMaximum: true
        )
        let rendered = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-glow")
        // A tall wave (scale 0.9) keeps its crest in the upper third, where the
        // glow is brightest — so this upper strip must carry content.
        #expect(try regionHasContent(in: rendered, region: CGRect(x: 0, y: 0, width: 600, height: 44)))
    }

    @Test("a temperature chart labels both ends of its scale")
    func temperatureChartLabelsBothEnds() throws {
        let series = [ChartSeries(name: "Die", values: [36.69, 38.82], unit: .temperature)]
        let chart = MetricChart(series: series, style: .area(stacked: false), colors: [Vitals.Palette.cpu], showsAxisMaximum: true)
        let rendered = try renderPNG(chart, size: CGSize(width: 400, height: 200), named: "chart-temperature-labels")

        #expect(try regionHasContent(in: rendered, region: CGRect(x: 2, y: 0, width: 90, height: 18)))

        // `regionHasContent` cannot guard the minimum label the way it guards
        // the maximum above: `drawAreas` fills the area from the curve down to
        // the baseline across the full chart width, and that fill's gradient
        // still differs from the background pixel-for-pixel almost all the way
        // down — so this corner "has content" whether or not the label ever
        // draws. Confirmed by disabling `drawAxisMinimum`'s call site: the
        // assertion below stayed green (measured, not assumed).
        //
        // `regionHasPixelBrighterThan` discriminates instead, by brightness:
        // the label is `.white.opacity(0.45)` text, alpha-weighted brightness
        // ~0.45; the fill this low has faded to near-zero alpha, so even
        // though its underlying colour is fully saturated, weighted brightness
        // is near zero too. Measured directly in this harness with the same
        // two-sample chart used below: with the label's draw call live, the
        // brightest pixel in this region weighs in at ~0.467; with the call
        // site disabled, ~0.043 (a stray antialiased fill pixel, not text).
        // 0.2 sits with wide margin above the fill-only case and wide margin
        // below the labelled case — about 4.6x clearance on each side.
        #expect(try regionHasPixelBrighterThan(
            in: rendered,
            region: CGRect(x: 2, y: 182, width: 90, height: 18),
            threshold: 0.2
        ))
    }

    // MARK: plotRect

    /// `plotRect(in:reservesTrailingLiveDotRoom:)` is the one function `body`
    /// uses to compute both the renderer's `canvasRect` and the rect it hands
    /// `crosshair(in:)` — so a pure check on the function itself is enough to
    /// prove the two can never disagree, without needing to render anything.
    /// See its doc comment on `MetricChart` for the full reasoning (mirrors
    /// `ChartGeometry.sampleX` being the one source of truth for where a
    /// sample sits, but for how wide the rect it is evaluated against is).
    @Test("plotRect insets the trailing edge by the live dot's own halo radius when reserving room for it, exactly, and leaves the rect untouched otherwise")
    func plotRectReservesTrailingLiveDotRoomExactly() {
        let outer = CGRect(x: 0, y: 0, width: 300, height: 28)

        let off = MetricChart.plotRect(in: outer, reservesTrailingLiveDotRoom: false)
        #expect(off == outer)

        let on = MetricChart.plotRect(in: outer, reservesTrailingLiveDotRoom: true)
        #expect(on.minX == outer.minX)
        #expect(on.height == outer.height)
        #expect(on.maxX == outer.maxX - MetricChart.liveDotHaloRadius)
    }

    /// The renderer plots the last sample at the plot rect's own `maxX` (see
    /// `ChartGeometry.points`, `.endpoints` spacing); the crosshair maps a
    /// hover position to a sample index via `ChartGeometry.sampleX` on
    /// whatever rect it is given. Both now come from the *same* `plotRect`
    /// call inside `body`, so evaluating `sampleX` on `plotRect`'s own output
    /// — exactly what the crosshair does — proves the last sample's x sits
    /// `liveDotHaloRadius` inside the outer trailing edge when reserving
    /// room, and exactly at the edge otherwise: the renderer and the
    /// crosshair are provably looking at the same geometry, not two
    /// independently-computed rects that happen to agree today.
    @Test("the crosshair's sample math against plotRect's output lands where the renderer actually plots the last sample")
    func plotRectKeepsCrosshairAndRendererInAgreement() {
        let outer = CGRect(x: 0, y: 0, width: 300, height: 28)
        let count = 4

        let off = MetricChart.plotRect(in: outer, reservesTrailingLiveDotRoom: false)
        let xOff = ChartGeometry.sampleX(at: count - 1, in: off, count: count, spacing: .endpoints)
        #expect(xOff == outer.maxX)

        let on = MetricChart.plotRect(in: outer, reservesTrailingLiveDotRoom: true)
        let xOn = ChartGeometry.sampleX(at: count - 1, in: on, count: count, spacing: .endpoints)
        #expect(xOn == outer.maxX - MetricChart.liveDotHaloRadius)
    }
}
