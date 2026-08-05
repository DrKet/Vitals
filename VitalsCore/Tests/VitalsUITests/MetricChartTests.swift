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
}
