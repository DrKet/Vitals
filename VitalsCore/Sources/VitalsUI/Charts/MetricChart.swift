import SwiftUI

public enum ChartStyle: Sendable, Equatable {
    /// Smoothed gradient bands. The house style.
    case area(stacked: Bool)
    /// Discrete bars, colour-ramped by load. Reads better at small sizes.
    case histogram
}

/// The one chart in Vitals. Two render modes over one geometry.
public struct MetricChart: View {
    private let series: [ChartSeries]
    private let style: ChartStyle
    private let colors: [Color]

    /// - Parameter series: **Order is load-bearing.** In stacked area mode the
    ///   first series is the base band and every later one accumulates on top of
    ///   it, so listing them in the wrong order silently redraws the
    ///   decomposition. The first series is also the one the live dot marks and
    ///   the one painted frontmost, so put the series a reader should track
    ///   first — Performance cores before Efficiency, download before upload.
    /// - Parameter colors: matched to `series` by index; wraps if shorter.
    public init(series: [ChartSeries], style: ChartStyle, colors: [Color]) {
        self.series = series
        self.style = style
        self.colors = colors
    }

    @State private var hoverX: CGFloat?

    public var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)

            Canvas { context, size in
                let canvasRect = CGRect(origin: .zero, size: size)
                drawGridlines(in: &context, rect: canvasRect)

                let bands = resolvedBands()
                guard !bands.isEmpty else { return }
                let bound = ChartGeometry.upperBound(for: bands)

                switch style {
                case .area:
                    drawAreas(bands, bound: bound, in: &context, rect: canvasRect)
                case .histogram:
                    drawHistogram(bands, bound: bound, in: &context, rect: canvasRect)
                }
            }
            .overlay { crosshair(in: rect) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
        }
        .frame(height: Vitals.Metrics.chartHeight)
    }

    @ViewBuilder
    private func crosshair(in rect: CGRect) -> some View {
        let sampleCount = series.map(\.values.count).max() ?? 0

        if let hoverX,
           let index = ChartGeometry.sampleIndex(atX: hoverX, in: rect, count: sampleCount),
           let readout = ChartGeometry.readout(at: index, series: series) {

            let step = sampleCount > 1 ? rect.width / CGFloat(sampleCount - 1) : 0
            let x = rect.minX + CGFloat(index) * step

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1)
                    .position(x: x, y: rect.midY)
                    .frame(height: rect.height)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(readout.values, id: \.name) { entry in
                        Text("\(entry.name)  \(Self.format(entry.value))")
                            .font(Vitals.Typography.label)
                    }
                }
                .padding(6)
                .glassSurface(cornerRadius: 8)
                // Kept inside the chart so the readout never clips off the edge.
                .offset(x: min(max(x + 8, 0), max(rect.width - 130, 0)), y: 6)
            }
        }
    }

    private static func format(_ value: Double) -> String {
        value <= 1.0
            ? "\(Int((value * 100).rounded()))%"
            : String(format: "%.2f", value)
    }

    /// Stacked mode accumulates; unstacked draws each series against the baseline.
    private func resolvedBands() -> [[Double]] {
        switch style {
        case .area(let stacked) where stacked:
            return ChartGeometry.stack(series)
        case .area, .histogram:
            return series.map(\.values).filter { !$0.isEmpty }
        }
    }

    private func drawGridlines(in context: inout GraphicsContext, rect: CGRect) {
        // Quarter lines give the eye a scale without competing with the data.
        for fraction in [0.25, 0.5, 0.75] {
            let y = rect.maxY - rect.height * fraction
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
    }

    private func drawAreas(
        _ bands: [[Double]],
        bound: Double,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        // Painted back to front so a lower band never hides the one beneath it.
        for (index, values) in bands.enumerated().reversed() {
            let color = colors.isEmpty ? Vitals.Palette.cpu : colors[index % colors.count]
            let points = ChartGeometry.points(values, in: rect, upperBound: bound)
            guard points.count > 1 else { continue }

            let line = ChartGeometry.smoothPath(through: points)

            var fill = line
            fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            fill.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.45), color.opacity(0)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
            context.stroke(line, with: .color(color), lineWidth: 2)

            // The live edge: the most recent sample, marked so the eye lands on
            // "now" rather than hunting for it.
            if index == 0, let last = points.last {
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 9, y: last.y - 9, width: 18, height: 18)),
                    with: .color(color.opacity(0.18))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                    with: .color(color)
                )
            }
        }
    }

    private func drawHistogram(
        _ bands: [[Double]],
        bound: Double,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        guard let values = bands.first, !values.isEmpty else { return }

        let slot = rect.width / CGFloat(values.count)
        let barWidth = max(slot * 0.7, 1)

        for (index, value) in values.enumerated() {
            let fraction = min(max(value / bound, 0), 1)
            let height = rect.height * fraction
            guard height > 0 else { continue }

            let bar = CGRect(
                x: rect.minX + CGFloat(index) * slot + (slot - barWidth) / 2,
                y: rect.maxY - height,
                width: barWidth,
                height: height
            )
            // Colour carries severity: bars warm toward amber as load climbs.
            let color = Vitals.Palette.cpu.mix(with: Vitals.Palette.gpu, by: fraction)
            context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 3), with: .color(color))
        }
    }
}
