import CoreGraphics
import SwiftUI

/// One named line or band on a chart. Values are oldest-first.
public struct ChartSeries: Sendable, Equatable {
    public let name: String
    public let values: [Double]

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }
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

    /// Maps values onto a rect, oldest at the leading edge, newest at the
    /// trailing edge. Y is inverted for screen space, and clamped so an
    /// out-of-range value cannot draw outside the chart.
    public static func points(
        _ values: [Double],
        in rect: CGRect,
        upperBound: Double
    ) -> [CGPoint] {
        guard !values.isEmpty, upperBound > 0 else { return [] }

        // A lone value belongs at the trailing edge: it is "now", not "the whole
        // history".
        guard values.count > 1 else {
            let clamped = min(max(values[0] / upperBound, 0), 1)
            return [CGPoint(x: rect.maxX, y: rect.maxY - clamped * rect.height)]
        }

        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let clamped = min(max(value / upperBound, 0), 1)
            return CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - clamped * rect.height
            )
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
