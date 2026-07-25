import CoreGraphics
import Testing
@testable import VitalsUI

@Suite("Chart scrubbing")
struct ChartScrubberTests {

    private let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

    @Test("the leading edge selects the oldest sample")
    func leadingEdgeSelectsOldest() {
        #expect(ChartGeometry.sampleIndex(atX: 0, in: rect, count: 5) == 0)
    }

    @Test("the trailing edge selects the newest sample")
    func trailingEdgeSelectsNewest() {
        #expect(ChartGeometry.sampleIndex(atX: 100, in: rect, count: 5) == 4)
    }

    @Test("a midpoint selects the nearest sample")
    func midpointSelectsNearest() {
        // 5 samples across 100pt sit at 0, 25, 50, 75, 100.
        #expect(ChartGeometry.sampleIndex(atX: 51, in: rect, count: 5) == 2)
        #expect(ChartGeometry.sampleIndex(atX: 64, in: rect, count: 5) == 3)
    }

    @Test("a position outside the chart selects nothing")
    func outsideSelectsNothing() {
        #expect(ChartGeometry.sampleIndex(atX: -5, in: rect, count: 5) == nil)
        #expect(ChartGeometry.sampleIndex(atX: 130, in: rect, count: 5) == nil)
    }

    @Test("an empty chart has nothing to select")
    func emptyChartSelectsNothing() {
        #expect(ChartGeometry.sampleIndex(atX: 50, in: rect, count: 0) == nil)
    }

    @Test("a readout reports every series' value at the scrubbed index")
    func readoutCoversAllSeries() throws {
        let series = [
            ChartSeries(name: "Performance", values: [0.1, 0.2, 0.3]),
            ChartSeries(name: "Efficiency", values: [0.4, 0.5, 0.6]),
        ]
        let readout = try #require(ChartGeometry.readout(at: 1, series: series))

        #expect(readout.index == 1)
        #expect(readout.values.count == 2)
        #expect(readout.values[0].name == "Performance")
        #expect(readout.values[0].value == 0.2)
        #expect(readout.values[1].value == 0.5)
    }

    @Test("a readout past the end of a short series omits it rather than inventing a value")
    func readoutOmitsShortSeries() throws {
        let series = [
            ChartSeries(name: "Performance", values: [0.1, 0.2, 0.3]),
            ChartSeries(name: "Efficiency", values: [0.4]),
        ]
        let readout = try #require(ChartGeometry.readout(at: 2, series: series))

        #expect(readout.values.count == 1)
        #expect(readout.values[0].name == "Performance")
    }

    @Test("a readout at an impossible index is nil")
    func impossibleIndexIsNil() {
        let series = [ChartSeries(name: "CPU", values: [0.1, 0.2])]
        #expect(ChartGeometry.readout(at: 9, series: series) == nil)
        #expect(ChartGeometry.readout(at: -1, series: series) == nil)
    }
}
