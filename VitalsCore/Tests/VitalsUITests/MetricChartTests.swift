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
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-area-single")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("renders stacked P-core and E-core bands, the CPU page's decomposition")
    func rendersStackedSeries() throws {
        let chart = MetricChart(
            series: [
                ChartSeries(name: "Performance", values: Self.wave(60, phase: 0, scale: 0.5)),
                ChartSeries(name: "Efficiency", values: Self.wave(60, phase: 2, scale: 0.2)),
            ],
            style: .area(stacked: true),
            colors: Vitals.seriesColors(count: 2)
        )
        let url = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-area-stacked")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("renders a histogram, the default at small widget sizes")
    func rendersHistogram() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: Self.wave(40, phase: 0, scale: 0.9))],
            style: .histogram,
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 600, height: 132), named: "chart-histogram")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a histogram of all-zero values draws no bars but still renders")
    func histogramOfZeroesRenders() throws {
        // Exercises the `height > 0` guard: every bar is skipped, so only the
        // gridlines remain. Still non-uniform, so the blank check holds.
        let chart = MetricChart(
            series: [ChartSeries(name: "Idle", values: Array(repeating: 0, count: 20))],
            style: .histogram,
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-histogram-zero")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an empty series renders without crashing")
    func emptySeriesRenders() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: [])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-empty")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a single sample renders without crashing")
    func singleSampleRenders() throws {
        let chart = MetricChart(
            series: [ChartSeries(name: "CPU", values: [0.4])],
            style: .area(stacked: false),
            colors: [Vitals.Palette.cpu]
        )
        let url = try renderPNG(chart, size: CGSize(width: 300, height: 132), named: "chart-single-sample")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
