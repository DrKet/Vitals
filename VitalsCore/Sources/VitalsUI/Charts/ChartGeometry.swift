import CoreGraphics
import Foundation
import SwiftUI

/// How a series' values should be read back to the user.
///
/// The unit is a property of the data, not something to be guessed from a
/// value's magnitude — a throughput reading of 0.05 MB/s must never be read
/// back as "5%" just because it happens to be below 1.
public enum ChartUnit: Sendable, Equatable {
    /// A 0...1 fraction, shown as a percentage.
    case fraction
    /// An absolute quantity with a unit suffix, e.g. "MB/s".
    case absolute(suffix: String)

    public func formatted(_ value: Double) -> String {
        switch self {
        case .fraction:
            return "\(Int((value * 100).rounded()))%"
        case .absolute(let suffix):
            return String(format: "%.2f %@", value, suffix)
        }
    }
}

/// One named line or band on a chart. Values are oldest-first.
public struct ChartSeries: Sendable, Equatable {
    public let name: String
    public let values: [Double]

    /// When each value was sampled, parallel to `values`.
    ///
    /// Empty means the series carries no time information: gap detection is
    /// skipped and the crosshair omits the age. That is the honest reading of
    /// "we don't know when", rather than inventing timestamps.
    public let timestamps: [TimeInterval]

    public let unit: ChartUnit

    /// Mismatched `values` and `timestamps` are truncated to their common
    /// prefix, never padded — the same rule `stack` uses, for the same reason:
    /// a padded entry would claim a measurement that was never taken.
    public init(
        name: String,
        values: [Double],
        timestamps: [TimeInterval] = [],
        unit: ChartUnit = .fraction
    ) {
        self.name = name
        self.unit = unit

        if timestamps.isEmpty {
            self.values = values
            self.timestamps = []
        } else {
            let common = min(values.count, timestamps.count)
            self.values = Array(values.prefix(common))
            self.timestamps = Array(timestamps.prefix(common))
        }
    }
}

/// How samples are distributed across a chart's width.
///
/// The two render styles genuinely differ, and the crosshair must use the same
/// model the renderer used or it will label the wrong sample.
public enum ChartSpacing: Sendable, Equatable {
    /// Samples sit *on* both edges, `width/(count-1)` apart. Area mode.
    case endpoints
    /// Samples sit at the centre of `width/count` slots, inset from both
    /// edges. Histogram mode.
    case slots
}

/// The maths behind both chart modes. Pure, and therefore the part that carries
/// the chart's test coverage — the SwiftUI layer over it is deliberately thin.
public enum ChartGeometry {

    /// Converts series into cumulative bands, so each sits on top of the last.
    ///
    /// Series of differing lengths are truncated to their common prefix rather
    /// than padded: padding a short series with zeroes would draw a band
    /// claiming a measurement that was never taken.
    public static func stack(_ series: [ChartSeries]) -> [[Double]] {
        guard let shortest = series.map(\.values.count).min(), shortest > 0 else { return [] }

        var running = [Double](repeating: 0, count: shortest)
        return series.map { entry in
            for index in 0..<shortest {
                running[index] += entry.values[index]
            }
            return running
        }
    }

    /// The smallest positive bound an absolute-unit chart is allowed, so an
    /// all-zero or empty series still yields a non-degenerate range instead of
    /// dividing by zero.
    public static let absoluteFloor: Double = 0.001

    /// A chart ceiling, paired with the number of decimal places needed to
    /// print it exactly.
    ///
    /// The two travel together because the precision is a property of the
    /// bound's own exponent, not a formatting choice: 0.05 needs two decimals
    /// and 50 needs none, and deriving that twice in two places is how they
    /// drift apart.
    public struct NiceBound: Sendable, Equatable {
        public let value: Double
        public let decimals: Int
    }

    /// The smallest `m x 10^n` with `m` in `{1, 2, 5, 10}` that is at least
    /// `peak`.
    ///
    /// Absolute-unit charts used to scale to the raw peak, which meant the
    /// bound moved on every tick and the whole chart reshaped itself on steady
    /// traffic. Rounding up to a round number holds the scale still between
    /// samples *and* gives the reader a ceiling worth labelling — an idle link
    /// and a saturated one no longer draw the same picture.
    ///
    /// `10` is in the multiplier list deliberately. `log10`/`pow` round-tripping
    /// is not exact: `log10(0.001)` can land at `-3.0000000000000004`, whose
    /// floor is `-4`, giving a mantissa of `10.0` that `{1, 2, 5}` alone cannot
    /// cover. Returning the first candidate at or above `peak` is also what
    /// enforces the invariant that matters — a bound *below* the peak would
    /// clip a real measurement, which is the same class of error as inventing
    /// one.
    public static func niceUpperBound(atLeast peak: Double) -> NiceBound {
        guard peak > 0, peak.isFinite else {
            return NiceBound(value: absoluteFloor, decimals: 3)
        }

        let exponent = Int(floor(log10(peak)))
        // Paired with the extra power of ten a 10x multiplier carries, so the
        // decimal count never needs a float comparison against the multiplier.
        let steps: [(multiplier: Double, exponentShift: Int)] = [(1, 0), (2, 0), (5, 0), (10, 1)]

        for step in steps {
            let candidate = step.multiplier * pow(10.0, Double(exponent))
            if candidate >= peak {
                return NiceBound(
                    value: candidate,
                    decimals: max(0, -(exponent + step.exponentShift))
                )
            }
        }

        // Unreachable while `exponent == floor(log10(peak))`: the 10x candidate
        // is a full decade above the peak's own. Total rather than trapping,
        // because float error in `log10` is the reason this list has four
        // entries and not three.
        return NiceBound(value: 10 * pow(10.0, Double(exponent)), decimals: max(0, -(exponent + 1)))
    }

    /// The value the top of the chart represents.
    ///
    /// Fractional metrics (CPU busy, GPU utilisation) are bounded at 1 so a 40%
    /// reading does not fill the frame. Absolute metrics (throughput,
    /// multi-core process CPU) grow to their own peak instead: a 1.0 floor
    /// would be meaningless for a metric with no natural ceiling, and for
    /// throughput in particular it is actively misleading — an idle disk or
    /// network link reads in the 0.001-0.05 MB/s range, and flooring that at
    /// 1.0 draws a flat line hugging the axis, indistinguishable from a
    /// broken chart. Absolute series still get a small positive floor so an
    /// all-zero or empty series yields a valid, non-degenerate range rather
    /// than dividing by zero.
    public static func upperBound(for stacked: [[Double]], unit: ChartUnit) -> Double {
        let peak = stacked.flatMap { $0 }.max() ?? 0
        switch unit {
        case .fraction:
            return max(peak, 1.0)
        case .absolute:
            // Through the same function `axisMaximum` uses, so the scale the
            // renderer plots against and the number the label prints cannot
            // disagree.
            return niceUpperBound(atLeast: max(peak, absoluteFloor)).value
        }
    }

    /// The labelled ceiling for an absolute-unit chart, or `nil` for a
    /// fractional one.
    ///
    /// Fractional charts are bounded at 1.0 and CPU, Memory and GPU all show
    /// that as a headline percentage already — a "100%" label on the canvas
    /// would restate what the page says in 40pt type.
    public static func axisMaximum(for stacked: [[Double]], unit: ChartUnit) -> NiceBound? {
        guard case .absolute = unit else { return nil }
        let peak = stacked.flatMap { $0 }.max() ?? 0
        return niceUpperBound(atLeast: max(peak, absoluteFloor))
    }

    /// `bound` rendered with its unit suffix, or `nil` for a fractional chart.
    ///
    /// Deliberately not `ChartUnit.formatted`, whose `%.2f` would print a
    /// 0.001 ceiling as "0.00 MB/s" — a ceiling of zero on a chart that is
    /// visibly not flat.
    public static func axisLabel(_ bound: NiceBound, unit: ChartUnit) -> String? {
        guard case .absolute(let suffix) = unit else { return nil }
        return String(format: "%.\(bound.decimals)f %@", bound.value, suffix)
    }

    /// Where sample `index` sits along `rect`'s width under a given spacing
    /// model. `nil` for an out-of-range index or a non-positive count.
    ///
    /// This is the one definition of where sample *n* lives: the renderer and
    /// the crosshair both call it, so they can never disagree about a
    /// sample's position.
    public static func sampleX(at index: Int, in rect: CGRect, count: Int, spacing: ChartSpacing) -> CGFloat? {
        guard count > 0, index >= 0, index < count else { return nil }

        switch spacing {
        case .endpoints:
            // A lone value belongs at the trailing edge: it is "now", not "the
            // whole history".
            guard count > 1 else { return rect.maxX }
            let step = rect.width / CGFloat(count - 1)
            return rect.minX + CGFloat(index) * step
        case .slots:
            let slot = rect.width / CGFloat(count)
            return rect.minX + CGFloat(index) * slot + slot / 2
        }
    }

    /// Maps values onto a rect, oldest at the leading edge, newest at the
    /// trailing edge. Y is inverted for screen space, and clamped so an
    /// out-of-range value cannot draw outside the chart.
    public static func points(
        _ values: [Double],
        in rect: CGRect,
        upperBound: Double
    ) -> [CGPoint] {
        guard !values.isEmpty, upperBound > 0 else { return [] }

        return values.enumerated().compactMap { index, value -> CGPoint? in
            guard let x = sampleX(at: index, in: rect, count: values.count, spacing: .endpoints) else {
                return nil
            }
            let clamped = min(max(value / upperBound, 0), 1)
            return CGPoint(x: x, y: rect.maxY - clamped * rect.height)
        }
    }

    /// Vertical breathing room to reserve at the plotting rect's edge so a
    /// boundary sample's stroke and its live marker stay inside the canvas —
    /// instead of clipping flat, part of the bug this exists to fix.
    ///
    /// Two independent things need covering, and the larger wins:
    ///
    /// - **The stroke.** It is centred on the path, so a point sitting
    ///   exactly on the rect's edge loses half its line width to the
    ///   boundary. That costs `strokeWidth / 2`.
    /// - **The live marker.** Drawn at the newest sample with its own
    ///   radius; if that sample is also the peak, the marker clips the same
    ///   way the stroke does. Pass its outer radius as `liveMarkerRadius`
    ///   (0 for an edge that never carries one, e.g. the bottom).
    ///
    /// A third cause used to live here: the Catmull-Rom curve between samples
    /// can swing past the sample it is approaching, which this function used
    /// to cover with a `0.75 * tension * rectHeight` reserve — a real,
    /// derived worst case, but a bad trade, since it stood in for space to
    /// keep drawing a value that was never measured, and it cost 18.75% of
    /// *every* chart's height to guard against a shape most renders never hit.
    /// `smoothPath` now clamps its own control points so the curve cannot
    /// leave the range spanned by the samples it interpolates (see its doc
    /// comment) — a structural fix at the source, not a margin sized to
    /// tolerate the defect. Overshoot needed no reserved space; it needed not
    /// to happen. With that gone, this function no longer depends on
    /// `rectHeight` at all: fixed physical quantities in, a fixed physical
    /// quantity out.
    public static func headroom(strokeWidth: CGFloat, liveMarkerRadius: CGFloat = 0) -> CGFloat {
        max(strokeWidth / 2, liveMarkerRadius)
    }

    /// `rect` with `top` and `bottom` points reserved as headroom.
    ///
    /// Only the vertical extent changes — `minX`/`width` pass through
    /// untouched — so `sampleX`, which depends only on those, places sample
    /// *n* identically whether it is handed this inset rect or the original.
    /// That is what keeps the renderer (which plots into the inset rect) and
    /// the crosshair (which still reads the outer rect) from ever disagreeing
    /// about where a sample sits horizontally.
    public static func insetForHeadroom(_ rect: CGRect, top: CGFloat, bottom: CGFloat = 0) -> CGRect {
        let height = max(rect.height - top - bottom, 0)
        return CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: height)
    }

    /// A Catmull-Rom smoothed path through the given points.
    ///
    /// Tangents are scaled by `tension` below the classic 0.5 so the curve stays
    /// close to its data. A monitoring chart that overshoots is drawing a value
    /// the machine never reported.
    ///
    /// Staying close is not the same as staying inside, though: even at a
    /// reduced tension, the curve between two samples can still swing above
    /// the higher of the two (or below the lower) when their neighbours pull
    /// the tangent hard enough — a local maximum flanked by a lower point on
    /// one side and a much lower one on the other is exactly that shape, and
    /// it is a realistic one (a burst that decays faster than it climbed), not
    /// an adversarial edge case. So each segment's two control points are
    /// clamped into the y-range spanned by *that segment's own* two endpoints
    /// (`p1.y` and `p2.y`) after being computed. A cubic Bezier always lies
    /// within the convex hull of its four control points — `p1`, `control1`,
    /// `control2`, `p2` — so once all four share that same y-range, the curve
    /// drawn between them cannot leave it either. That holds independently at
    /// every segment and at every chart height, which is what makes this a
    /// structural fix rather than a margin sized to cover the worst case: there
    /// is no worst case left to size for, at the top of a peak or the bottom of
    /// a trough.
    ///
    /// Only `y` is clamped. `x` is monotonic across the whole series by
    /// construction (`points` places samples left to right), so a control
    /// point's `x` straying slightly outside its segment never draws the curve
    /// backwards or off the chart horizontally the way an unclamped `y` does
    /// vertically.
    public static func smoothPath(through points: [CGPoint]) -> Path {
        guard points.count > 1 else { return Path() }

        let tension: CGFloat = 0.25
        var path = Path()
        path.move(to: points[0])

        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]

            let segmentMinY = min(p1.y, p2.y)
            let segmentMaxY = max(p1.y, p2.y)

            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension,
                y: min(max(p1.y + (p2.y - p0.y) * tension, segmentMinY), segmentMaxY)
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension,
                y: min(max(p2.y - (p3.y - p1.y) * tension, segmentMinY), segmentMaxY)
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

// MARK: - Time axis

extension ChartGeometry {

    /// The largest interval between consecutive samples that still counts as
    /// continuous.
    ///
    /// Derived from the data rather than hard-coded, so it adapts if the
    /// sampling cadence changes. Uses the **median** interval, not the mean: a
    /// single hour-long absence would drag a mean far enough up to swallow
    /// every other gap, which is precisely the case this exists to catch.
    ///
    /// `nil` when there are fewer than two timestamps — not enough information
    /// to judge, and guessing would be fabrication.
    public static func gapThreshold(for timestamps: [TimeInterval]) -> TimeInterval? {
        guard timestamps.count >= 2 else { return nil }

        let intervals = zip(timestamps, timestamps.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0 }
            .sorted()
        guard !intervals.isEmpty else { return nil }

        let median = intervals[intervals.count / 2]
        return median * 3
    }

    /// Index ranges of contiguously-sampled runs.
    ///
    /// Sampling is subscription-driven, so leaving a page stops it: a chart
    /// that drew straight through the resulting hole would assert a continuity
    /// the machine never reported. Splitting into segments lets the renderer
    /// leave the gap empty.
    ///
    /// Untimestamped series yield one range covering everything, so they render
    /// exactly as before.
    public static func segments(
        timestamps: [TimeInterval],
        threshold: TimeInterval
    ) -> [Range<Int>] {
        guard !timestamps.isEmpty else { return [] }
        guard timestamps.count > 1, threshold > 0 else { return [0..<timestamps.count] }

        var result: [Range<Int>] = []
        var start = 0

        for index in 1..<timestamps.count {
            if timestamps[index] - timestamps[index - 1] > threshold {
                result.append(start..<index)
                start = index
            }
        }
        result.append(start..<timestamps.count)
        return result
    }

    /// Segments for a series, using its own timestamps. One full-coverage range
    /// when the series carries no time information.
    public static func segments(for series: ChartSeries) -> [Range<Int>] {
        guard !series.values.isEmpty else { return [] }
        guard let threshold = gapThreshold(for: series.timestamps) else {
            return [0..<series.values.count]
        }
        return segments(timestamps: series.timestamps, threshold: threshold)
    }

    /// How long before `now` a sample was taken, phrased for a rolling chart.
    ///
    /// Relative rather than a wall clock: on a chart of the last ten minutes,
    /// the reader wants to know how old a point is, not what time it was.
    public static func relativeAge(of timestamp: TimeInterval, now: TimeInterval) -> String {
        let age = now - timestamp
        guard age >= 1 else { return "now" }

        let seconds = Int(age.rounded())
        if seconds < 60 { return "\(seconds)s ago" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h ago" : "\(hours)h \(remainder)m ago"
    }
}
