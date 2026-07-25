import CoreGraphics
import Testing
@testable import VitalsUI

@Suite("Chart scrubbing")
struct ChartScrubberTests {

    private let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

    @Test("the leading edge selects the oldest sample")
    func leadingEdgeSelectsOldest() {
        #expect(ChartGeometry.sampleIndex(atX: 0, in: rect, count: 5, spacing: .endpoints) == 0)
    }

    @Test("the trailing edge selects the newest sample")
    func trailingEdgeSelectsNewest() {
        #expect(ChartGeometry.sampleIndex(atX: 100, in: rect, count: 5, spacing: .endpoints) == 4)
    }

    @Test("a midpoint selects the nearest sample")
    func midpointSelectsNearest() {
        // 5 samples across 100pt sit at 0, 25, 50, 75, 100.
        #expect(ChartGeometry.sampleIndex(atX: 51, in: rect, count: 5, spacing: .endpoints) == 2)
        #expect(ChartGeometry.sampleIndex(atX: 64, in: rect, count: 5, spacing: .endpoints) == 3)
    }

    @Test("a position outside the chart selects nothing")
    func outsideSelectsNothing() {
        #expect(ChartGeometry.sampleIndex(atX: -5, in: rect, count: 5, spacing: .endpoints) == nil)
        #expect(ChartGeometry.sampleIndex(atX: 130, in: rect, count: 5, spacing: .endpoints) == nil)
    }

    @Test("an empty chart has nothing to select")
    func emptyChartSelectsNothing() {
        #expect(ChartGeometry.sampleIndex(atX: 50, in: rect, count: 0, spacing: .endpoints) == nil)
    }

    // MARK: Slot spacing (histogram mode)

    @Test("in slot spacing, samples centre inside their slot rather than sitting on the edges")
    func slotSpacingCentresSamples() {
        // 5 samples across 100pt sit at 10, 30, 50, 70, 90 — inset from both
        // edges, unlike endpoints spacing.
        #expect(ChartGeometry.sampleX(at: 0, in: rect, count: 5, spacing: .slots) == 10)
        #expect(ChartGeometry.sampleX(at: 4, in: rect, count: 5, spacing: .slots) == 90)
        #expect(ChartGeometry.sampleX(at: 2, in: rect, count: 5, spacing: .slots) == 50)
    }

    @Test("in slot spacing, hovering the leading edge still selects the first sample")
    func slotSpacingLeadingEdgeSelectsFirst() {
        #expect(ChartGeometry.sampleIndex(atX: 0, in: rect, count: 5, spacing: .slots) == 0)
    }

    @Test("in slot spacing, hovering the trailing edge still selects the last sample")
    func slotSpacingTrailingEdgeSelectsLast() {
        #expect(ChartGeometry.sampleIndex(atX: 100, in: rect, count: 5, spacing: .slots) == 4)
    }

    @Test("in slot spacing, a position near a bar's centre selects that bar")
    func slotSpacingMidpointSelectsNearest() {
        // Slot boundaries fall at 0, 20, 40, 60, 80, 100 for 5 samples.
        #expect(ChartGeometry.sampleIndex(atX: 25, in: rect, count: 5, spacing: .slots) == 1)
        #expect(ChartGeometry.sampleIndex(atX: 65, in: rect, count: 5, spacing: .slots) == 3)
    }

    @Test("a single sample under endpoints spacing sits at the trailing edge, matching the live dot")
    func singleSampleSampleXSitsAtTrailingEdge() {
        #expect(ChartGeometry.sampleX(at: 0, in: rect, count: 1, spacing: .endpoints) == rect.maxX)
    }

    @Test("hovering a single sample's trailing edge under endpoints spacing selects it")
    func singleSampleTrailingEdgeSelectsIt() {
        #expect(ChartGeometry.sampleIndex(atX: rect.maxX, in: rect, count: 1, spacing: .endpoints) == 0)
    }

    @Test("sampleX is nil for an out-of-range index or a non-positive count")
    func sampleXIsNilOutOfRange() {
        #expect(ChartGeometry.sampleX(at: -1, in: rect, count: 5, spacing: .endpoints) == nil)
        #expect(ChartGeometry.sampleX(at: 5, in: rect, count: 5, spacing: .endpoints) == nil)
        #expect(ChartGeometry.sampleX(at: 0, in: rect, count: 0, spacing: .endpoints) == nil)
        #expect(ChartGeometry.sampleX(at: 0, in: rect, count: 5, spacing: .slots) != nil)
        #expect(ChartGeometry.sampleX(at: 5, in: rect, count: 5, spacing: .slots) == nil)
    }

    // MARK: Readout box placement

    @Test("the readout anchors trailing (to the right) when the pointer is in the left half")
    func readoutAnchorsTrailingInLeftHalf() {
        let boxSize = CGSize(width: 40, height: 20)
        let origin = ChartGeometry.readoutOrigin(atX: 20, in: rect, boxSize: boxSize)
        #expect(origin.x == 28) // 20 + 8pt margin
    }

    @Test("the readout anchors leading (to the left) when the pointer is in the right half")
    func readoutAnchorsLeadingInRightHalf() {
        let boxSize = CGSize(width: 40, height: 20)
        let origin = ChartGeometry.readoutOrigin(atX: 80, in: rect, boxSize: boxSize)
        #expect(origin.x == 32) // 80 - 8pt margin - 40pt width
    }

    @Test("the readout is clamped horizontally so it never crosses the chart's edges")
    func readoutClampsHorizontally() {
        // A box wider than the room available on the anchored side would
        // overflow if not clamped against the chart's far edge.
        let boxSize = CGSize(width: 90, height: 20)
        let leftOrigin = ChartGeometry.readoutOrigin(atX: 20, in: rect, boxSize: boxSize)
        #expect(leftOrigin.x + boxSize.width <= rect.maxX)
        #expect(leftOrigin.x >= rect.minX)

        let rightOrigin = ChartGeometry.readoutOrigin(atX: 80, in: rect, boxSize: boxSize)
        #expect(rightOrigin.x >= rect.minX)
        #expect(rightOrigin.x + boxSize.width <= rect.maxX)
    }

    @Test("the readout is clamped vertically so a tall box never crosses the chart's bottom edge")
    func readoutClampsVertically() {
        // Tall enough (45pt in a 50pt-high chart) that the default 8pt
        // top margin would push its bottom edge past the chart — the clamp
        // must pull it back up rather than let it overflow.
        let tallBox = CGSize(width: 40, height: 45)
        let origin = ChartGeometry.readoutOrigin(atX: 20, in: rect, boxSize: tallBox)
        #expect(origin.y >= rect.minY)
        #expect(origin.y + tallBox.height <= rect.maxY)
        #expect(origin.y < 8) // pulled up from the ideal 8pt margin
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
