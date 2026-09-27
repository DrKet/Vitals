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
        #expect(ChartGeometry.upperBound(for: [[0.1, 0.4]], unit: .fraction) == 1.0)
    }

    @Test("a fractional series exceeding 1 grows the bound to its peak")
    func unboundedSeriesUsesPeak() {
        // Per-process CPU is not a fraction — a process on four cores
        // legitimately reads 4.0.
        #expect(ChartGeometry.upperBound(for: [[0.5, 3.2]], unit: .fraction) == 3.2)
    }

    @Test("an all-zero fractional series still has a positive bound, so nothing divides by zero")
    func zeroSeriesHasPositiveBound() {
        #expect(ChartGeometry.upperBound(for: [[0, 0, 0]], unit: .fraction) == 1.0)
    }

    @Test("an absolute series below 1 scales to its own peak, not a 1.0 floor")
    func absoluteSeriesBelowOneScalesToOwnPeak() {
        // Storage/Network idle throughput sits in the 0.001-0.05 MB/s range.
        // Flooring that at 1.0 would render as a flat line hugging the axis.
        let bound = ChartGeometry.upperBound(for: [[0.01, 0.05]], unit: .absolute(suffix: "MB/s"))
        #expect(abs(bound - 0.05) < 1e-9)
    }

    @Test("an absolute series exceeding 1 still grows to its peak, rounded up to a nice value")
    func absoluteSeriesAboveOneUsesPeak() {
        // 3.2 is not itself "nice" (a 1/2/5x power of ten), so upperBound now
        // rounds it up to 5 — see niceBoundRoundsUp for the general rule this
        // exercises. Before the stable-axis change, this asserted an exact
        // peak of 3.2; that equality is precisely what rounding intentionally
        // supersedes, so the assertion moves to the rounded value rather than
        // the bound reverting to raw-peak behaviour to keep it.
        #expect(abs(ChartGeometry.upperBound(for: [[0.5, 3.2]], unit: .absolute(suffix: "MB/s")) - 5.0) < 1e-9)
    }

    @Test("an all-zero or empty absolute series has a small positive bound, so nothing divides by zero")
    func zeroAbsoluteSeriesHasPositiveBound() {
        #expect(ChartGeometry.upperBound(for: [[0, 0, 0]], unit: .absolute(suffix: "MB/s")) > 0)
        #expect(ChartGeometry.upperBound(for: [], unit: .absolute(suffix: "MB/s")) > 0)
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
        // Multi-value, not just a single point: an earlier version of this
        // test only exercised the single-value branch, which could not catch
        // a clamp that broke for anything past index 0.
        let points = ChartGeometry.points([2.0, 3.0, 0.5], in: rect, upperBound: 1.0)
        #expect(points.count == 3)
        #expect(points[0].y == 0)
        #expect(points[1].y == 0)
        #expect(points[2].y == 25)
    }

    @Test("a negative value is clamped to the baseline, never drawing below the rect")
    func negativeValuesAreClampedToBaseline() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = ChartGeometry.points([-1.0, -0.5], in: rect, upperBound: 1.0)
        #expect(points[0].y == rect.maxY)
        #expect(points[1].y == rect.maxY)
    }

    // MARK: sampleX

    @Test("endpoints spacing places samples on both edges, evenly stepped between")
    func sampleXEndpointsSpansEdges() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(ChartGeometry.sampleX(at: 0, in: rect, count: 5, spacing: .endpoints) == 0)
        #expect(ChartGeometry.sampleX(at: 4, in: rect, count: 5, spacing: .endpoints) == 100)
        #expect(ChartGeometry.sampleX(at: 2, in: rect, count: 5, spacing: .endpoints) == 50)
    }

    @Test("endpoints spacing with one sample sits at the trailing edge, where 'now' lives")
    func sampleXEndpointsSingleSampleSitsAtTrailingEdge() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(ChartGeometry.sampleX(at: 0, in: rect, count: 1, spacing: .endpoints) == rect.maxX)
    }

    // MARK: ChartUnit

    @Test("a fraction unit renders as a whole-number percentage")
    func fractionUnitFormatsAsPercentage() {
        #expect(ChartUnit.fraction.formatted(0.05) == "5%")
        #expect(ChartUnit.fraction.formatted(0.5) == "50%")
    }

    @Test("an absolute unit below 1.0 does not render as a percentage — the regression this exists to prevent")
    func absoluteUnitBelowOneIsNotAPercentage() {
        // Before this fix, MetricChart.format guessed the unit from magnitude:
        // any value <= 1.0 rendered as a percentage, so a 0.05 MB/s download
        // read as "5%". The unit must now be explicit, not inferred.
        #expect(ChartUnit.absolute(suffix: "MB/s").formatted(0.05) == "0.05 MB/s")
    }

    @Test("an absolute unit renders two decimal places plus its suffix")
    func absoluteUnitFormatsWithSuffix() {
        #expect(ChartUnit.absolute(suffix: "MB/s").formatted(3.2) == "3.20 MB/s")
    }

    @Test("a series defaults to the fraction unit so existing call sites keep their behaviour")
    func seriesDefaultsToFractionUnit() {
        let series = ChartSeries(name: "CPU", values: [0.5])
        #expect(series.unit == .fraction)
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

    // MARK: Nice bound / axis label

    @Test("a nice upper bound rounds up to 1, 2 or 5 times a power of ten")
    func niceBoundRoundsUp() {
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 41.25).value - 50) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 0.12).value - 0.2) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 0.03).value - 0.05) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 10).value - 10) < 1e-9)
        #expect(abs(ChartGeometry.niceUpperBound(atLeast: 6).value - 10) < 1e-9)
    }

    /// The invariant that matters: a bound below the peak would clip real data,
    /// which is the same class of error as inventing it. Swept across five
    /// decades rather than spot-checked, because the failure mode is
    /// floating-point and floating-point failures hide between the cases
    /// anyone thinks to write by hand.
    @Test("a nice upper bound is never below the peak it must contain")
    func niceBoundNeverClips() {
        var peak = 0.001
        while peak < 10_000 {
            let bound = ChartGeometry.niceUpperBound(atLeast: peak)
            #expect(bound.value >= peak, "bound \(bound.value) is below peak \(peak)")
            peak *= 1.07
        }
    }

    /// `log10(0.001)` can land at -3.0000000000000004, whose floor is -4,
    /// producing a mantissa of 10.0 that a {1, 2, 5} multiplier list cannot
    /// cover. This is why the list has a 10 in it.
    @Test("the float-error case at an exact power of ten is covered")
    func niceBoundHandlesExactPowersOfTen() {
        for exponent in -4...4 {
            let peak = pow(10.0, Double(exponent))
            let bound = ChartGeometry.niceUpperBound(atLeast: peak)
            #expect(bound.value >= peak)
            #expect(abs(bound.value - peak) < peak * 1e-9, "\(peak) should already be nice")
        }
    }

    /// `peak.isFinite` guards `Int(floor(log10(peak)))` below it: without it,
    /// `+infinity` reaches that conversion and `Int(Double.infinity)` is a
    /// Swift runtime trap, not a thrown error. Every degenerate input —
    /// zero, negative, NaN, and infinite — must be caught before that line
    /// and turned into the same honest floor.
    @Test("degenerate peaks fall back to the absolute floor instead of reaching the log")
    func degeneratePeaksFallBackToFloor() {
        for peak in [0.0, -1.0, Double.nan, Double.infinity] {
            let bound = ChartGeometry.niceUpperBound(atLeast: peak)
            #expect(abs(bound.value - ChartGeometry.absoluteFloor) < 1e-12)
            #expect(bound.decimals == 3)
        }
    }

    @Test("decimal places are derived from the bound's own exponent")
    func niceBoundDecimals() {
        #expect(ChartGeometry.niceUpperBound(atLeast: 41.25).decimals == 0)
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.12).decimals == 1)
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.03).decimals == 2)
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.001).decimals == 3)
        // 0.06 rounds to 0.1 — a 10x multiplier, so one decimal, not two.
        #expect(ChartGeometry.niceUpperBound(atLeast: 0.06).decimals == 1)
    }

    @Test("fractional charts keep their 1.0 ceiling and get no label")
    func fractionalChartsAreUntouched() {
        let bands = [[0.2, 0.4, 0.37]]
        #expect(abs(ChartGeometry.upperBound(for: bands, unit: .fraction) - 1.0) < 1e-9)
        #expect(ChartGeometry.axisMaximum(for: bands, unit: .fraction) == nil)
    }

    /// A drift guard. The scale the renderer plots against and the number the
    /// label prints must come from the same computation, or the chart will one
    /// day say 50 while drawing against 41.25.
    @Test("the axis label's value is exactly the bound the chart plots against")
    func axisMaximumAgreesWithUpperBound() {
        let bands = [[0.01, 41.25, 3.0]]
        let unit = ChartUnit.absolute(suffix: "MB/s")
        let axis = ChartGeometry.axisMaximum(for: bands, unit: unit)
        #expect(abs(axis!.value - ChartGeometry.upperBound(for: bands, unit: unit)) < 1e-9)
    }

    @Test("an axis label prints its suffix at the derived precision")
    func axisLabelFormatting() {
        let unit = ChartUnit.absolute(suffix: "MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 41.25), unit: unit) == "50 MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 0.12), unit: unit) == "0.2 MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 0.001), unit: unit) == "0.001 MB/s")
        #expect(ChartGeometry.axisLabel(ChartGeometry.niceUpperBound(atLeast: 0.5), unit: .fraction) == nil)
    }

    // MARK: Temperature bounds

    /// The rule: round outward to multiples of 5, and push off the axis when
    /// the data lands exactly on one. A baseline tracking raw min/max would
    /// move every tick and reshape the chart on steady readings — the defect
    /// the previous milestone removed from absolute charts.
    @Test("temperature bounds round outward to multiples of five")
    func temperatureBoundsRoundOutward() {
        // The spike's real capture: die, battery and storage together.
        let bands = [[36.69, 38.82], [28.50, 28.80], [29.00, 32.00]]
        let bounds = ChartGeometry.bounds(for: bands, unit: .temperature)
        #expect(abs(bounds.lower - 25) < 1e-9)
        #expect(abs(bounds.upper - 40) < 1e-9)
    }

    /// Data sitting exactly on a multiple of 5 must not be drawn on the axis
    /// itself, and the span must never collapse to zero.
    @Test("temperature bounds push off the axis when data lands on a multiple")
    func temperatureBoundsAvoidTheAxis() {
        let bounds = ChartGeometry.bounds(for: [[30.0, 30.0]], unit: .temperature)
        #expect(abs(bounds.lower - 25) < 1e-9)
        #expect(abs(bounds.upper - 35) < 1e-9)
        #expect(bounds.upper - bounds.lower >= 5)
    }

    @Test("a temperature chart labels both ends")
    func temperatureLabelsBothEnds() {
        let bands = [[36.69, 38.82]]
        let low = ChartGeometry.axisMinimum(for: bands, unit: .temperature)
        let high = ChartGeometry.axisMaximum(for: bands, unit: .temperature)
        #expect(ChartGeometry.axisLabel(low!, unit: .temperature) == "35 °C")
        #expect(ChartGeometry.axisLabel(high!, unit: .temperature) == "40 °C")
    }

    /// Zero-based units have nothing worth labelling at the bottom — a "0"
    /// restates what the baseline already says.
    @Test("zero-based units have no minimum label")
    func zeroBasedUnitsHaveNoMinimumLabel() {
        #expect(ChartGeometry.axisMinimum(for: [[0.4]], unit: .fraction) == nil)
        #expect(ChartGeometry.axisMinimum(for: [[41.25]], unit: .absolute(suffix: "MB/s")) == nil)
    }

    /// The load-bearing regression guard: adding a unit case must not move any
    /// existing chart by a single point.
    @Test("existing units are byte-identical through the new bounds function")
    func existingUnitsAreUnchanged() {
        let bands = [[0.2, 0.4, 0.37]]
        #expect(abs(ChartGeometry.bounds(for: bands, unit: .fraction).lower) < 1e-9)
        #expect(abs(ChartGeometry.bounds(for: bands, unit: .fraction).upper - 1.0) < 1e-9)

        let absolute = [[0.01, 41.25]]
        let unit = ChartUnit.absolute(suffix: "MB/s")
        #expect(abs(ChartGeometry.bounds(for: absolute, unit: unit).lower) < 1e-9)
        // Against a literal, not against `upperBound`: that function is now
        // implemented AS `bounds(...).upper`, so comparing the two compares a
        // value with itself and could not fail however badly `.absolute`
        // regressed. 41.25 rounds up to the nice bound 50.
        #expect(abs(ChartGeometry.bounds(for: absolute, unit: unit).upper - 50) < 1e-9)
    }

    @Test("a temperature formats to one decimal with a degree suffix")
    func temperatureFormatting() {
        #expect(ChartUnit.temperature.formatted(38.82) == "38.8 °C")
    }

    // MARK: hasPlottableValues

    /// `MetricTile` and `MenuBarPanel`'s dropdown rows both gate their chart
    /// on this one predicate instead of each carrying its own copy — see its
    /// doc comment. The CPU tile's/row's series is always exactly one
    /// `ChartSeries`; on a freshly empty store it is present but carries no
    /// values, so a looser `!series.isEmpty` would still be true and would
    /// reserve a chart band (drawing faint gridlines) for a reading that was
    /// never taken.
    @Test("hasPlottableValues mirrors the never-fabricate rule: no series, or series with no values, is not chart data")
    func hasPlottableValuesMatchesEmptinessRule() {
        #expect([ChartSeries]().hasPlottableValues == false)
        #expect([ChartSeries(name: "CPU", values: [])].hasPlottableValues == false)
        #expect([ChartSeries(name: "CPU", values: [0.4])].hasPlottableValues == true)
    }
}
