import CoreGraphics
import Testing
@testable import VitalsUI

/// `0.2 + 0.1 != 0.3` under IEEE-754 double precision, so tests that assert on
/// summed values compare with a tolerance rather than exact equality.
private func isApproximatelyEqual(_ lhs: [[Double]], _ rhs: [[Double]], tolerance: Double = 1e-9) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { lhsRow, rhsRow in
        guard lhsRow.count == rhsRow.count else { return false }
        return zip(lhsRow, rhsRow).allSatisfy { abs($0 - $1) < tolerance }
    }
}

@Suite("Chart geometry")
struct ChartGeometryTests {

    // MARK: Stacking

    @Test("a single series stacks to itself")
    func singleSeriesStacksToItself() {
        let stacked = ChartGeometry.stack([ChartSeries(name: "a", values: [0.2, 0.4])])
        #expect(stacked == [[0.2, 0.4]])
    }

    @Test("stacked series accumulate so bands sit on top of one another")
    func seriesAccumulate() {
        let stacked = ChartGeometry.stack([
            ChartSeries(name: "p", values: [0.2, 0.3]),
            ChartSeries(name: "e", values: [0.1, 0.1]),
        ])
        // 0.2 + 0.1 is not exactly representable as a Double (it evaluates to
        // 0.30000000000000004), so this compares with tolerance rather than `==`.
        #expect(isApproximatelyEqual(stacked, [[0.2, 0.3], [0.3, 0.4]]))
    }

    @Test("series of differing lengths stack over their common prefix")
    func raggedSeriesUseCommonPrefix() {
        let stacked = ChartGeometry.stack([
            ChartSeries(name: "p", values: [0.2, 0.3, 0.4]),
            ChartSeries(name: "e", values: [0.1, 0.1]),
        ])
        #expect(isApproximatelyEqual(stacked, [[0.2, 0.3], [0.3, 0.4]]))
    }

    @Test("stacking nothing yields nothing")
    func emptyInputStacksToNothing() {
        #expect(ChartGeometry.stack([]).isEmpty)
    }

    // MARK: Upper bound

    @Test("a fractional series is bounded at 1 so 40% does not fill the chart")
    func fractionalSeriesBoundedAtOne() {
        #expect(ChartGeometry.upperBound(for: [[0.1, 0.4]]) == 1.0)
    }

    @Test("a series exceeding 1 grows the bound to its peak")
    func unboundedSeriesUsesPeak() {
        // Throughput and per-process CPU are not fractions — a process on four
        // cores legitimately reads 4.0.
        #expect(ChartGeometry.upperBound(for: [[0.5, 3.2]]) == 3.2)
    }

    @Test("an all-zero series still has a positive bound, so nothing divides by zero")
    func zeroSeriesHasPositiveBound() {
        #expect(ChartGeometry.upperBound(for: [[0, 0, 0]]) == 1.0)
    }

    // MARK: Point mapping

    @Test("values map across the full width with y inverted for screen space")
    func valuesMapToRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([0, 0.5, 1.0], in: rect, upperBound: 1.0)

        #expect(points.count == 3)
        #expect(points[0] == CGPoint(x: 0, y: 50))    // zero sits on the baseline
        #expect(points[1] == CGPoint(x: 50, y: 25))
        #expect(points[2] == CGPoint(x: 100, y: 0))   // full value reaches the top
    }

    @Test("a single value is placed at the trailing edge, where 'now' lives")
    func singleValueSitsAtTrailingEdge() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([0.5], in: rect, upperBound: 1.0)
        #expect(points == [CGPoint(x: 100, y: 25)])
    }

    @Test("no values map to no points")
    func emptyValuesMapToNoPoints() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(ChartGeometry.points([], in: rect, upperBound: 1.0).isEmpty)
    }

    @Test("values above the bound are clamped inside the rect")
    func valuesAboveBoundAreClamped() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([2.0], in: rect, upperBound: 1.0)
        #expect(points[0].y == 0)
    }

    // MARK: Smoothing

    @Test("no points make no path")
    func smoothPathIsEmptyForNoPoints() {
        #expect(ChartGeometry.smoothPath(through: []).isEmpty)
    }

    @Test("a smoothed path of one point is empty — a point is not a line")
    func smoothPathNeedsTwoPoints() {
        #expect(ChartGeometry.smoothPath(through: [CGPoint(x: 0, y: 0)]).isEmpty)
    }

    @Test("a smoothed path spans from the first point to the last")
    func smoothPathSpansInput() {
        let points = [
            CGPoint(x: 0, y: 40), CGPoint(x: 25, y: 10),
            CGPoint(x: 50, y: 30), CGPoint(x: 75, y: 5),
        ]
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect
        #expect(bounds.minX == 0)
        #expect(bounds.maxX == 75)
    }

    @Test("smoothing does not overshoot the input's vertical range excessively")
    func smoothPathDoesNotOvershootWildly() {
        // Catmull-Rom can overshoot on sharp spikes. A monitor's chart must not
        // draw a curve implying a value the machine never reported, so the
        // overshoot is bounded.
        let points = [
            CGPoint(x: 0, y: 50), CGPoint(x: 25, y: 50),
            CGPoint(x: 50, y: 0), CGPoint(x: 75, y: 50),
        ]
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect

        // The bound is deliberately loose enough to be independent of whether
        // `boundingRect` includes control points: at tension 0.25 the highest
        // control point is y=62.5, while classic tension 0.5 would put it at
        // y=75. So this still fails if the smoothing is retuned to overshoot,
        // which is the regression it exists to catch.
        #expect(bounds.minY >= -15)
        #expect(bounds.maxY <= 65)
    }
}
