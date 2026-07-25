import CoreGraphics

/// What the crosshair reports at one position.
public struct ScrubReadout: Sendable, Equatable {
    public let index: Int
    public let values: [Named]

    public struct Named: Sendable, Equatable {
        public let name: String
        public let value: Double
    }
}

extension ChartGeometry {

    /// The sample nearest a horizontal position, or `nil` outside the chart.
    public static func sampleIndex(atX x: CGFloat, in rect: CGRect, count: Int) -> Int? {
        guard count > 0, x >= rect.minX, x <= rect.maxX else { return nil }
        guard count > 1 else { return 0 }

        let step = rect.width / CGFloat(count - 1)
        let index = Int(((x - rect.minX) / step).rounded())
        return min(max(index, 0), count - 1)
    }

    /// Every series' value at one index.
    ///
    /// A series too short to reach the index is omitted rather than reported as
    /// zero — the crosshair must not invent a measurement.
    public static func readout(at index: Int, series: [ChartSeries]) -> ScrubReadout? {
        guard index >= 0 else { return nil }
        let named = series.compactMap { entry -> ScrubReadout.Named? in
            guard index < entry.values.count else { return nil }
            return ScrubReadout.Named(name: entry.name, value: entry.values[index])
        }
        guard !named.isEmpty else { return nil }
        return ScrubReadout(index: index, values: named)
    }
}
