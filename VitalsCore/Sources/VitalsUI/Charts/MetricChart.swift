import Foundation
import SwiftUI

public enum ChartStyle: Sendable, Equatable {
    /// Smoothed gradient bands. The house style.
    case area(stacked: Bool)
    /// Discrete bars, colour-ramped by load. Reads better at small sizes.
    ///
    /// Known limitation: `drawHistogram` only renders `bands.first` — with
    /// more than one series, every band after the first is silently dropped.
    /// No UI reaches multi-series histogram mode yet, but the spec allows
    /// histogram as a selectable style on any chart, and a four-way stack
    /// (Memory) would hit this today if wired up.
    case histogram

    /// The spacing model this style renders samples with. The crosshair uses
    /// this so it can never disagree with the renderer about where a sample
    /// sits.
    var spacing: ChartSpacing {
        switch self {
        case .area: return .endpoints
        case .histogram: return .slots
        }
    }
}

/// The one chart in Vitals. Two render modes over one geometry.
public struct MetricChart: View {
    private let series: [ChartSeries]
    private let style: ChartStyle
    private let colors: [Color]
    private let showsAxisMaximum: Bool

    /// - Parameter series: **Order is load-bearing.** In stacked area mode the
    ///   first series is the base band and every later one accumulates on top of
    ///   it, so listing them in the wrong order silently redraws the
    ///   decomposition. The first series is also the one the live dot marks and
    ///   the one painted frontmost, so put the series a reader should track
    ///   first — Performance cores before Efficiency, download before upload.
    /// - Parameter colors: matched to `series` by index; wraps if shorter.
    /// - Parameter showsAxisMaximum: Whether an absolute-unit series draws its
    ///   ceiling (see `drawAxisMaximum`). No default on purpose: this chart is
    ///   embedded both on hardware pages, which carry no other number for the
    ///   reading's scale, and in `MetricTile` on the Overview, which already
    ///   states the same quantity as its own headline — a second copy in 11pt
    ///   grey directly beneath it restates what the tile just said. The
    ///   ceiling label was added for the former and silently inherited by the
    ///   latter, which is exactly the bug a defaulted parameter would let
    ///   happen again the next time a new embedder shows up. Requiring every
    ///   call site to choose is what stops that.
    public init(series: [ChartSeries], style: ChartStyle, colors: [Color], showsAxisMaximum: Bool) {
        self.series = series
        self.style = style
        self.colors = colors
        self.showsAxisMaximum = showsAxisMaximum
    }

    @State private var hoverX: CGFloat?

    /// The stroke width `drawAreas` paints a band's boundary line with.
    /// Shared with `ChartGeometry.headroom` so the top margin it reserves is
    /// always derived from the same width the stroke actually uses.
    private static let strokeWidth: CGFloat = 2
    /// The live dot's outer halo radius (see `drawAreas`). Also fed to
    /// `ChartGeometry.headroom`: if the newest sample is the peak, the dot
    /// needs the same clearance the stroke and the smoothing curve do.
    private static let liveDotHaloRadius: CGFloat = 9
    private static let liveDotRadius: CGFloat = 3

    public var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)

            Canvas { context, size in
                let canvasRect = CGRect(origin: .zero, size: size)
                let bands = resolvedBands()

                guard !bands.isEmpty else {
                    drawGridlines(in: &context, rect: canvasRect)
                    return
                }
                // All series on one chart share a unit — see `unit(for:)` —
                // so the first is representative of the whole chart.
                let chartUnit = series.first?.unit ?? .fraction
                let scale = ChartGeometry.bounds(for: bands, unit: chartUnit)

                switch style {
                case .area(let stacked):
                    // Gridlines are drawn against the *same* inset rect as the
                    // data, not the raw canvas: they mark fractions of the
                    // value scale, and that scale now lives inside
                    // `plotRect`. Drawing them against `canvasRect` instead
                    // would leave the 50% line, say, not actually passing
                    // through the chart's own 50%-height data.
                    let topHeadroom = ChartGeometry.headroom(
                        strokeWidth: Self.strokeWidth,
                        liveMarkerRadius: Self.liveDotHaloRadius
                    )
                    // The bottom gets no equivalent inset. A centred stroke
                    // sitting exactly at `rect.maxY` still loses half its
                    // width the same way it does at the top, but
                    // `smoothPath`'s clamp (see its doc comment) already
                    // removes the *smoothing*-driven undershoot that used to
                    // make a trough dip below the canvas — that part is fixed
                    // structurally now, not merely tolerated. What's left is
                    // only the stroke's own half-width at a literal-zero
                    // sample, which is far less visible than the old
                    // full-curve dip: the fill's gradient already fades to
                    // zero alpha at exactly that edge (see the
                    // `.linearGradient` below), so only the thin opaque
                    // stroke tip is ever affected, and there is no live dot
                    // at the bottom to protect. Reserving space here for
                    // that alone would cost real chart height on every
                    // render for a defect that is barely visible in
                    // practice — see the chart-headroom report for the
                    // pixel-level comparison this was based on.
                    let plotRect = ChartGeometry.insetForHeadroom(canvasRect, top: topHeadroom)
                    drawGridlines(in: &context, rect: plotRect)
                    drawAreas(
                        bands,
                        fillOpacity: Self.fillOpacity(stacked: stacked, bandCount: bands.count),
                        lowerBound: scale.lower,
                        upperBound: scale.upper,
                        in: &context,
                        rect: plotRect
                    )
                    drawAxisMaximum(bands, unit: chartUnit, in: &context, rect: plotRect)
                    drawAxisMinimum(bands, unit: chartUnit, in: &context, rect: plotRect)
                case .histogram:
                    // Bars are filled shapes anchored to `rect.maxY`, not a
                    // centred stroke or a smoothed curve between samples —
                    // neither clipping mechanism this exists for applies, so
                    // histogram mode keeps the full canvas. They also always
                    // start from zero regardless of unit: a bar's length is
                    // read as its magnitude, and a floating baseline would
                    // make two bars of equal height represent different
                    // readings. `scale.lower` is deliberately not threaded in
                    // here — only the area path floats.
                    drawGridlines(in: &context, rect: canvasRect)
                    drawHistogram(bands, bound: scale.upper, in: &context, rect: canvasRect)
                    drawAxisMaximum(bands, unit: chartUnit, in: &context, rect: canvasRect)
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
        // A floor, not a fixed size: the chart claims leftover vertical space
        // so a tall tile shows more history rather than more emptiness.
        .frame(minHeight: Vitals.Metrics.chartHeight, maxHeight: .infinity)
    }

    @ViewBuilder
    private func crosshair(in rect: CGRect) -> some View {
        // Derived from `resolvedBands()` — the same values `body`'s `Canvas`
        // paints — rather than the raw series lengths. In stacked area mode
        // `ChartGeometry.stack` truncates ragged series to their shortest
        // common length, so a count taken from the raw series (as this used
        // to do) could exceed what was actually drawn, letting the crosshair
        // land on a sample the renderer never painted.
        let sampleCount = resolvedBands().map(\.count).max() ?? 0
        let spacing = style.spacing

        if let hoverX,
           let index = ChartGeometry.sampleIndex(atX: hoverX, in: rect, count: sampleCount, spacing: spacing),
           let readout = ChartGeometry.readout(at: index, series: series),
           let x = ChartGeometry.sampleX(at: index, in: rect, count: sampleCount, spacing: spacing) {

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1)
                    .position(x: x, y: rect.midY)
                    .frame(height: rect.height)

                // Anchored to whichever side of the crosshair has more room and
                // clamped in both axes against the box's real size — see
                // `ReadoutPlacement`, which measures it during layout rather
                // than routing it back through view state.
                ReadoutPlacement(anchorX: x) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let timestamp = readout.timestamp {
                            Text(ChartGeometry.relativeAge(
                                of: timestamp,
                                now: ProcessInfo.processInfo.systemUptime
                            ))
                            .font(Vitals.Typography.label)
                            .foregroundStyle(.secondary)
                        }
                        ForEach(readout.values, id: \.name) { entry in
                            Text("\(entry.name)  \(unit(for: entry.name).formatted(entry.value))")
                                .font(Vitals.Typography.label)
                        }
                    }
                    .padding(6)
                    .glassSurface(cornerRadius: 8)
                }
            }
        }
    }

    /// The series named `name`'s unit, or `.fraction` if no series matches —
    /// the crosshair must never guess a unit from a value's magnitude.
    private func unit(for name: String) -> ChartUnit {
        series.first(where: { $0.name == name })?.unit ?? .fraction
    }

    /// Stacked mode accumulates; unstacked draws each series against the baseline.
    ///
    /// Internal rather than private so tests can confirm the crosshair's
    /// sample count (derived from this) can never disagree with what
    /// actually got painted — see `MetricChartTests`.
    func resolvedBands() -> [[Double]] {
        switch style {
        case .area(let stacked) where stacked:
            return ChartGeometry.stack(series)
        case .area, .histogram:
            return series.map(\.values).filter { !$0.isEmpty }
        }
    }

    /// The y-max, drawn at the plot rect's top-leading corner.
    ///
    /// Absolute-unit charts only: they scale to their own data and would
    /// otherwise draw an idle link and a saturated one identically. Painted
    /// into the `Canvas`, so the crosshair overlay — a transient hover state on
    /// an opaque background — draws over it. That overlap is accepted; moving
    /// a transient readout to dodge a static label is not worth the coupling.
    ///
    /// Gated on `showsAxisMaximum` on top of the unit check: an embedder that
    /// already states the same reading elsewhere (`MetricTile`'s headline)
    /// opts out here rather than the chart guessing from context.
    private func drawAxisMaximum(
        _ bands: [[Double]],
        unit chartUnit: ChartUnit,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        guard showsAxisMaximum,
              let bound = ChartGeometry.axisMaximum(for: bands, unit: chartUnit),
              let label = ChartGeometry.axisLabel(bound, unit: chartUnit) else { return }

        var text = context.resolve(Text(label).font(Vitals.Typography.label))
        text.shading = .color(.white.opacity(0.45))
        context.draw(text, at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: .topLeading)
    }

    /// The y-min, drawn at the plot rect's bottom-leading corner — the
    /// mirror image of `drawAxisMaximum`.
    ///
    /// `ChartGeometry.axisMinimum` only ever returns non-nil for a unit whose
    /// scale floats (temperature today): a fractional or absolute chart's
    /// floor is a known, silent zero, so labelling it would spend ink telling
    /// the reader what the axis already implies. Gated on `showsAxisMaximum`
    /// too, for the same reason the maximum is — an embedder that opted out
    /// of the ceiling label because it already states the reading elsewhere
    /// (`MetricTile`'s headline) should not get the floor label as a
    /// consolation prize.
    private func drawAxisMinimum(
        _ bands: [[Double]],
        unit chartUnit: ChartUnit,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        guard showsAxisMaximum,
              let bound = ChartGeometry.axisMinimum(for: bands, unit: chartUnit),
              let label = ChartGeometry.axisLabel(bound, unit: chartUnit) else { return }

        var text = context.resolve(Text(label).font(Vitals.Typography.label))
        text.shading = .color(.white.opacity(0.45))
        context.draw(text, at: CGPoint(x: rect.minX + 4, y: rect.maxY - 2), anchor: .bottomLeading)
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

    /// How opaque the gradient beneath a band is.
    ///
    /// Stacked bands tile: each sits on the one below, so their fills abut
    /// rather than overlap and the full-weight gradient reads exactly as spec
    /// §6.3 describes. Unstacked bands do not — several independent readings
    /// at different heights each fill down to the same baseline, so the
    /// highest one's sheet lies over every line beneath it. On the Sensors
    /// page that buried two of three series and made an unstacked chart read
    /// as a stacked one.
    ///
    /// Keyed on overlap rather than on the unit, because the problem is
    /// geometric rather than anything to do with temperature — any future
    /// non-additive page inherits the fix. And gated on there being something
    /// to overlap: a single band cannot cover anything, so an Overview tile
    /// (which passes `stacked: series.count > 1`, i.e. `false` when it has one
    /// series) keeps its full-weight fill.
    static func fillOpacity(stacked: Bool, bandCount: Int) -> Double {
        stacked || bandCount < 2 ? 0.45 : 0.15
    }

    private func drawAreas(
        _ bands: [[Double]],
        fillOpacity: Double,
        lowerBound: Double,
        upperBound: Double,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        // Painted back to front (highest index first) so series 0 is painted
        // last. Translucent fills (see `fillOpacity`) are what actually
        // keep every band visible regardless of paint order — this ordering
        // instead controls the opaque strokes and the live dot: series 0's
        // stroke ends up on top of every other band's, and its live dot
        // (drawn only for index == 0) is never occluded by a band painted
        // after it.
        for (index, values) in bands.enumerated().reversed() {
            let color = colors.isEmpty ? Vitals.Palette.cpu : colors[index % colors.count]
            let points = ChartGeometry.points(values, in: rect, lowerBound: lowerBound, upperBound: upperBound)
            guard points.count > 1 else { continue }

            // Sampling stops when a page is not on screen, so history can
            // contain holes. Each contiguously-sampled run is drawn on its own;
            // nothing is drawn across a gap, because a line there would assert
            // a continuity the machine never reported.
            let runs = ChartGeometry.segments(for: seriesForSegmentation(at: index))

            for run in runs {
                let slice = Array(points[run.clamped(to: 0..<points.count)])
                guard slice.count > 1 else { continue }

                let line = ChartGeometry.smoothPath(through: slice)

                var fill = line
                fill.addLine(to: CGPoint(x: slice[slice.count - 1].x, y: rect.maxY))
                fill.addLine(to: CGPoint(x: slice[0].x, y: rect.maxY))
                fill.closeSubpath()

                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(fillOpacity), color.opacity(0)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
                context.stroke(line, with: .color(color), lineWidth: Self.strokeWidth)
            }

            // The live edge: the most recent sample, marked so the eye lands on
            // "now" rather than hunting for it. Only on the newest run — a dot
            // on a stale segment would read as current.
            if index == 0, let last = points.last {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: last.x - Self.liveDotHaloRadius, y: last.y - Self.liveDotHaloRadius,
                        width: Self.liveDotHaloRadius * 2, height: Self.liveDotHaloRadius * 2
                    )),
                    with: .color(color.opacity(0.18))
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: last.x - Self.liveDotRadius, y: last.y - Self.liveDotRadius,
                        width: Self.liveDotRadius * 2, height: Self.liveDotRadius * 2
                    )),
                    with: .color(color)
                )
            }
        }
    }

    /// The series whose timestamps describe band `index`.
    ///
    /// Stacking merges series into cumulative bands, but they were all sampled
    /// at the same moments, so any series' timestamps describe every band.
    private func seriesForSegmentation(at index: Int) -> ChartSeries {
        series.indices.contains(index) ? series[index] : (series.first ?? ChartSeries(name: "", values: []))
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
            guard let centerX = ChartGeometry.sampleX(at: index, in: rect, count: values.count, spacing: .slots) else {
                continue
            }
            let fraction = min(max(value / bound, 0), 1)
            let height = rect.height * fraction
            guard height > 0 else { continue }

            let bar = CGRect(
                x: centerX - barWidth / 2,
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
