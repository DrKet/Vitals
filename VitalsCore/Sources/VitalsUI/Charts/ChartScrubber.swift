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
    ///
    /// `spacing` must match whatever model the renderer used to place the
    /// samples — area and histogram mode lay samples out differently, and
    /// passing the wrong one silently selects the wrong sample.
    public static func sampleIndex(atX x: CGFloat, in rect: CGRect, count: Int, spacing: ChartSpacing) -> Int? {
        guard count > 0, x >= rect.minX, x <= rect.maxX else { return nil }
        guard count > 1 else { return 0 }

        switch spacing {
        case .endpoints:
            let step = rect.width / CGFloat(count - 1)
            let index = Int(((x - rect.minX) / step).rounded())
            return min(max(index, 0), count - 1)
        case .slots:
            // Slot boundaries fall exactly on the midpoint between adjacent
            // centres, so simple slot membership already gives the nearest
            // sample — no rounding needed.
            let slot = rect.width / CGFloat(count)
            let index = Int((x - rect.minX) / slot)
            return min(max(index, 0), count - 1)
        }
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

    /// Where the readout box's top-left origin should land so it never
    /// overflows the chart, regardless of its rendered size.
    ///
    /// Anchored to whichever side of `x` has more room — trailing (to the
    /// right) when `x` is in the left half of the chart, leading (to the
    /// left) when it's in the right half — then clamped in both axes so the
    /// box's far edge can never cross `rect`'s bounds.
    public static func readoutOrigin(atX x: CGFloat, in rect: CGRect, boxSize: CGSize, margin: CGFloat = 8) -> CGPoint {
        let onLeftHalf = x < rect.midX
        let idealX = onLeftHalf ? x + margin : x - margin - boxSize.width
        let clampedX = min(max(idealX, rect.minX), max(rect.maxX - boxSize.width, rect.minX))

        let idealY = rect.minY + margin
        let clampedY = min(max(idealY, rect.minY), max(rect.maxY - boxSize.height, rect.minY))

        return CGPoint(x: clampedX, y: clampedY)
    }
}
