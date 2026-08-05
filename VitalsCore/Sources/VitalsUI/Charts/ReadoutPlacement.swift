import SwiftUI

/// Places the crosshair's readout box inside a chart, clamped to the chart
/// whenever it fits.
struct ReadoutPlacement: Layout {
    /// Where on the chart's x-axis the readout is reporting from, expressed
    /// against the chart's own zero-origin rect — `CGRect(origin: .zero,
    /// size: proxy.size)` in `MetricChart`'s `GeometryReader` — NOT against
    /// `bounds` as received by `placeSubviews`.
    ///
    /// Those two are not the same rect, and the only caller has no way to
    /// make them the same: Apple documents `bounds.origin` as "not
    /// necessarily `(0, 0)`," and in this app's real layout it measurably
    /// isn't (`bounds.minX` ≈ 13.5pt on the Network page). `bounds` is only
    /// ever known inside `placeSubviews`, once SwiftUI has already decided
    /// where this layout sits in its parent — `MetricChart` cannot predict it
    /// when computing `anchorX`, so it computes against the one rect it does
    /// control, its own zero-origin canvas. `placeSubviews` is therefore the
    /// place that reconciles the two coordinate spaces, not this parameter.
    let anchorX: CGFloat

    /// Fills whatever space is proposed, rather than sizing to the readout
    /// box's own dimensions, whenever a size is proposed.
    ///
    /// This is the invariant the whole fix depends on: `placeSubviews`
    /// receives `bounds` equal to the chart's own rect only because this
    /// method reports that it wants the chart's full proposed size. If it
    /// reported the box's intrinsic size instead, `ReadoutPlacement` would
    /// shrink to fit its child, `bounds` would stop being the chart's rect,
    /// and `anchorX` — computed in the chart's coordinate space — would be
    /// clamped and placed against the wrong rectangle entirely.
    ///
    /// A `nil` dimension in `proposal` means "you decide," not "there is no
    /// space" — collapsing it to `0` would report a zero-sized footprint for
    /// this whole `Layout` to whatever embeds it (a sibling `.background`, a
    /// `GeometryReader` measuring it, anything that trusts the size a layout
    /// reports rather than re-measuring its content itself). `placeSubviews`
    /// below still independently re-measures and paints the one subview at
    /// its own true size regardless of what this method reports, so a `?? 0`
    /// regression here does not make the rendered box vanish — it only makes
    /// this `Layout`'s own reported size a lie. `replacingUnspecifiedDimensions`
    /// avoids that by falling back to the subview's own preferred size
    /// instead of fabricating zero.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return proposal.replacingUnspecifiedDimensions(by: subview.sizeThatFits(.unspecified))
    }

    /// The fix for the readout clipping off a chart's right edge.
    ///
    /// The placement maths (`ChartGeometry.readoutOrigin`) was never wrong; it
    /// was being handed a `boxSize` of `.zero`. `MetricChart` used to measure
    /// the box through a `PreferenceKey` seeded at `.zero` and feed the result
    /// back through `@State`, which meant the first hover positioned against a
    /// zero-width box — and, confirmed by holding a stationary cursor at a
    /// chart's right edge in the running app, never corrected afterwards.
    ///
    /// A `Layout` has no such first frame: `bounds` and
    /// `subviews[0].sizeThatFits(.unspecified)` are both available in this one
    /// call, so the clamp is computed against a real size the first time it is
    /// computed at all. No state, no preference, no second pass.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Contract, not an oversight: this layout exists for exactly one
        // readout box. A second (or zeroth) view in the builder closure is
        // silently ignored here rather than placed or asserted against —
        // matching `sizeThatFits`'s `subviews.first` above.
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)

        // `anchorX` arrives in the chart's own zero-origin rect (`MetricChart`
        // computes it against `CGRect(origin: .zero, size: proxy.size)`), while
        // `bounds` is in the parent's space and Apple documents its origin as not
        // necessarily (0, 0) — measured at x = 13.5 in this app's real layout.
        // Clamping in a zero-origin copy and translating afterwards is what keeps
        // the two from disagreeing, whatever SwiftUI hands us.
        let local = CGRect(origin: .zero, size: bounds.size)
        let origin = ChartGeometry.readoutOrigin(atX: anchorX, in: local, boxSize: size)
        subview.place(
            at: CGPoint(x: origin.x + bounds.minX, y: origin.y + bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}
