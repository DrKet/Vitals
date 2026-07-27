import CoreGraphics
import Testing
@testable import VitalsUI

/// A peak that touches the top of the chart gets visibly cut off: the stroke is
/// centred on the path, so half its width falls outside the canvas, and the
/// smoothing curve can rise above the peak sample itself. Both are clipped, so
/// a spike renders with a flat, chopped top.
///
/// Two independent mechanisms, two independent fixes:
///
/// - **The stroke and the live marker** need real physical space, so
///   `MetricChart` insets the rect it plots into
///   (`ChartGeometry.insetForHeadroom`) by `ChartGeometry.headroom`. That
///   happens at the `MetricChart` call site, not inside `ChartGeometry.points`
///   itself — `points` stays exactly as `ChartGeometryTests` pins it (a value
///   at the upper bound still maps to `rect.minY` when called with the raw
///   rect), so these tests apply the same headroom+inset the renderer does
///   before calling `points`/`smoothPath`, rather than expecting `points` to
///   reserve margin on its own.
/// - **The smoothing curve** does not get reserved space at all. It gets
///   fixed at the source: `smoothPath` clamps each segment's control points
///   into the y-range spanned by that segment's own two endpoints, so the
///   curve can no longer leave the range of the samples it interpolates —
///   at the top *or* the bottom — regardless of chart height. See
///   `ChartGeometry.smoothPath`'s doc comment for why the convex-hull
///   property makes that clamp sufficient. An earlier version of this fix
///   reserved `0.75 * tension * rectHeight` of headroom to *tolerate* the
///   overshoot instead of removing it — 18.75% of every chart's height,
///   permanently — which is why `headroom` below no longer takes a
///   `rectHeight` or `tension` parameter at all.
@Suite("Chart headroom")
struct ChartHeadroomTests {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 100)

    /// The stroke width and live-marker radius `MetricChart` actually uses —
    /// duplicated here (rather than imported) because they are private
    /// implementation details of `MetricChart`; keeping the values in sync is
    /// exactly what `headroomCoversStrokeWidthAtMinimum` and
    /// `headroomCoversLiveMarkerAtMinimum` are for: if `MetricChart` changes
    /// them, those checks stop matching production headroom and the
    /// render-level check in `MetricChartTests` catches the drift.
    private let strokeWidth: CGFloat = 2
    private let liveMarkerRadius: CGFloat = 9

    private func plotRect(for rect: CGRect) -> CGRect {
        let top = ChartGeometry.headroom(strokeWidth: strokeWidth, liveMarkerRadius: liveMarkerRadius)
        return ChartGeometry.insetForHeadroom(rect, top: top)
    }

    // MARK: Mechanism 1 — the stroke

    @Test("a value at the upper bound does not sit on the very top edge, once headroom is applied")
    func peakLeavesRoomForItsStroke() {
        // MetricChart strokes at lineWidth 2, centred on the path, so a point at
        // y == rect.minY loses its top 1pt to the canvas edge. The fix insets
        // the rect handed to `points` before mapping, so the peak now lands
        // inside `plotRect`, off the outer rect's true edge.
        let inset = plotRect(for: rect)
        let points = ChartGeometry.points([1.0], in: inset, upperBound: 1.0)
        let peak = try! #require(points.first)
        #expect(peak.y >= rect.minY + strokeWidth / 2)
    }

    @Test("ChartGeometry.points itself is unchanged — a value at the bound still reaches rect.minY when called with the raw rect")
    func rawPointsMappingIsUntouched() {
        // Pinning this negatively: the fix must not move into `points` itself,
        // because `ChartGeometryTests.valuesMapToRect` and
        // `singleValueSitsAtTrailingEdge` pin its exact output (e.g. "full
        // value reaches the top") for the raw rect. Headroom has to live at
        // the call site (the inset rect handed in), not inside the pure
        // mapping function, or those pinned assertions would go wrong.
        let points = ChartGeometry.points([1.0], in: rect, upperBound: 1.0)
        #expect(points.first?.y == rect.minY)
    }

    // MARK: Mechanism 2 — smoothing overshoot, fixed by clamping, not headroom

    @Test("the smoothed curve through a spike stays inside the chart, with no headroom applied at all")
    func smoothingOvershootStaysInsideTheChart() {
        // `points` clamps each SAMPLE into the rect, but the Catmull-Rom curve
        // BETWEEN samples used to not be clamped: a local maximum pulled the
        // control points above the peak, so the drawn curve left the canvas
        // even though every sample was inside it. `smoothPath` now clamps its
        // own control points, so this holds against the raw `rect` — no
        // `plotRect`/headroom needed for this mechanism at all.
        // Asymmetric on purpose. A symmetric spike is the one shape that cannot
        // overshoot: the Catmull-Rom tangent at the peak is (next - previous),
        // which is zero when the neighbours match. Overshoot appears when the
        // sample after the peak is lower than the one before it.
        let spike = [0.1, 0.5, 1.0, 0.1, 0.1]
        let points = ChartGeometry.points(spike, in: rect, upperBound: 1.0)
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect

        #expect(bounds.minY >= rect.minY)
        #expect(bounds.maxY <= rect.maxY)
    }

    @Test("the smoothed curve through the analytically worst-case double-peak stays inside the chart, top and bottom")
    func smoothingOvershootWorstCaseStaysInsideTheChart() {
        // The exact worst case for a single (unclamped) Catmull-Rom segment:
        // two consecutive samples pegged at the peak, flanked on both sides by
        // samples at the opposite extreme (baseline). Mirrored, the same shape
        // is also the worst case for a trough undershooting the bottom. Both
        // directions are covered by the same clamp, so both are asserted here.
        let doublePeak = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
        let points = ChartGeometry.points(doublePeak, in: rect, upperBound: 1.0)
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect

        #expect(bounds.minY >= rect.minY)
        #expect(bounds.maxY <= rect.maxY)
    }

    @Test("the smoothed curve through the mirrored worst-case double-trough stays inside the chart at the bottom")
    func smoothingUndershootWorstCaseStaysInsideTheChart() {
        // The previous (reserve-space) design left bottom undershoot
        // unfixed — headroom was only ever applied to the top, and the old
        // report's own investigation found the stroke tip genuinely clipped
        // at `rect.maxY`. Clamping fixes this for free, with no bottom inset
        // at all: two consecutive samples pegged at the *baseline*, flanked by
        // samples at the peak, is the mirror image of the double-peak case
        // above and pulls the curve below `rect.maxY` if uncorrected.
        let doubleTrough = [1.0, 1.0, 0.0, 0.0, 1.0, 1.0]
        let points = ChartGeometry.points(doubleTrough, in: rect, upperBound: 1.0)
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect

        #expect(bounds.maxY <= rect.maxY)
        #expect(bounds.minY >= rect.minY)
    }

    @Test(
        "the clamp keeps the curve inside the canvas from a small tile up to a tall stretched window, with no headroom needed",
        arguments: [32.0, 100.0, 132.0, 400.0, 1200.0, 4000.0]
    )
    func smoothingStaysInsideAcrossChartHeights(height: Double) {
        // Under the old design, headroom had to scale with `rectHeight`
        // because the reserved margin was a fraction of it — a fixed pixel
        // headroom that happened to cover a 132pt chart would be silently too
        // small the moment the window (and therefore the chart, which grows
        // to fill available space) got taller. The clamp has no such
        // dependency: it constrains the curve to the samples' own range at
        // every height, so this holds against the raw, un-inset rect
        // regardless of how tall it is.
        let tallRect = CGRect(x: 0, y: 0, width: 200, height: height)
        let doublePeak = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
        let points = ChartGeometry.points(doublePeak, in: tallRect, upperBound: 1.0)
        let bounds = ChartGeometry.smoothPath(through: points).boundingRect

        #expect(bounds.minY >= tallRect.minY, "overshot at height \(height)")
        #expect(bounds.maxY <= tallRect.maxY, "undershot at height \(height)")

        // The stroke case still needs headroom (a physical stroke width has
        // no notion of "scale with chart height"), so confirm it separately
        // at the same height, inset by the (now height-independent) headroom.
        let inset = plotRect(for: tallRect)
        let peakPoints = ChartGeometry.points([1.0], in: inset, upperBound: 1.0)
        let peak = try! #require(peakPoints.first)
        #expect(peak.y >= tallRect.minY + strokeWidth / 2, "stroke clipped at height \(height)")
    }

    // MARK: Mechanism 3 — the live dot

    @Test("the live dot at the newest sample does not clip when that sample is the peak")
    func liveDotDoesNotClipAtThePeak() {
        // The dot is drawn at `points.last` with its own halo radius,
        // independent of the stroke. If the newest sample is also the peak
        // (the common case for a `.absolute` chart, whose upperBound equals
        // its own peak), the dot needs the same clearance as the stroke.
        let values = [0.2, 0.5, 1.0]
        let inset = plotRect(for: rect)
        let points = ChartGeometry.points(values, in: inset, upperBound: 1.0)
        let last = try! #require(points.last)
        #expect(last.y - liveMarkerRadius >= rect.minY)
    }

    // MARK: ChartGeometry.headroom

    @Test("headroom reserves at least half the stroke width even when the live marker is smaller")
    func headroomCoversStrokeWidthAtMinimum() {
        let headroom = ChartGeometry.headroom(strokeWidth: 2, liveMarkerRadius: 0)
        #expect(headroom >= 1)
    }

    @Test("headroom reserves the live marker's radius when it is the largest term")
    func headroomCoversLiveMarkerAtMinimum() {
        let headroom = ChartGeometry.headroom(strokeWidth: 2, liveMarkerRadius: 9)
        #expect(headroom >= 9)
    }

    @Test("headroom is independent of chart height — only the stroke and the marker are physical quantities that need reserving")
    func headroomDoesNotScaleWithHeight() {
        // The old design's headroom grew with `rectHeight` because it was
        // reserving a fraction of it for smoothing overshoot. That term is
        // gone — `smoothPath` fixes overshoot by clamping, not by giving it
        // room to happen — so `headroom` no longer takes a height at all, and
        // MetricChart's actual top inset stays flat and small (a couple of
        // points' worth of stroke/marker) instead of growing to consume 18.75%
        // of a tall chart's height.
        let headroom = ChartGeometry.headroom(strokeWidth: 2, liveMarkerRadius: 9)
        #expect(abs(headroom - 9) < 0.001)
    }

    // MARK: ChartGeometry.insetForHeadroom

    @Test("insetting for headroom leaves sampleX's inputs (minX, width) untouched, so the crosshair cannot drift out of sync")
    func insetPreservesXBounds() {
        // `sampleX` depends only on `minX` and `width`. Insetting only the
        // vertical extent means the renderer (which plots into the inset
        // rect) and the crosshair (which still reads the outer rect) agree on
        // where sample n sits, without either needing to know about the
        // other's rect.
        let inset = ChartGeometry.insetForHeadroom(rect, top: 20, bottom: 5)
        #expect(inset.minX == rect.minX)
        #expect(inset.width == rect.width)
        for index in 0..<5 {
            let onOuter = ChartGeometry.sampleX(at: index, in: rect, count: 5, spacing: .endpoints)
            let onInset = ChartGeometry.sampleX(at: index, in: inset, count: 5, spacing: .endpoints)
            #expect(onOuter == onInset)
        }
    }

    @Test("insetting for headroom reduces height by exactly top + bottom, and moves the origin down by top")
    func insetReducesHeightByTopPlusBottom() {
        let inset = ChartGeometry.insetForHeadroom(rect, top: 20, bottom: 5)
        #expect(inset.minY == rect.minY + 20)
        #expect(inset.height == rect.height - 25)
        #expect(inset.maxY == rect.maxY - 5)
    }

    @Test("insetting for headroom never produces a negative height, for a degenerate rect smaller than its own headroom")
    func insetClampsToZeroHeight() {
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
        let inset = ChartGeometry.insetForHeadroom(tiny, top: 40, bottom: 40)
        #expect(inset.height == 0)
    }
}
