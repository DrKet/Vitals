import CoreGraphics
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
    public let unit: ChartUnit

    public init(name: String, values: [Double], unit: ChartUnit = .fraction) {
        self.name = name
        self.values = values
        self.unit = unit
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

    /// The value the top of the chart represents.
    ///
    /// Fractional metrics (CPU busy, GPU utilisation) are bounded at 1 so a 40%
    /// reading does not fill the frame. Unbounded metrics (throughput,
    /// multi-core process CPU) grow to their own peak.
    public static func upperBound(for stacked: [[Double]]) -> Double {
        let peak = stacked.flatMap { $0 }.max() ?? 0
        return max(peak, 1.0)
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

    /// A Catmull-Rom smoothed path through the given points.
    ///
    /// Tangents are scaled by `tension` below the classic 0.5 so the curve stays
    /// close to its data. A monitoring chart that overshoots is drawing a value
    /// the machine never reported.
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

            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension,
                y: p1.y + (p2.y - p0.y) * tension
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension,
                y: p2.y - (p3.y - p1.y) * tension
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}
