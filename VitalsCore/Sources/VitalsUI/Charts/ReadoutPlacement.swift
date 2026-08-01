import SwiftUI

/// Places the crosshair's readout box inside a chart, clamped to the chart
/// whenever it fits.
struct ReadoutPlacement: Layout {
    /// Where on the chart's x-axis the readout is reporting from, in the
    /// chart's own coordinate space — the same rect this layout receives as
    /// `bounds` in `placeSubviews`, not the enclosing window or screen.
    ///
    /// `CGRect.bounds.origin` is not guaranteed to be `(0, 0)` — a caller that
    /// computed `anchorX` in some other coordinate space and handed it to a
    /// `ReadoutPlacement` whose `bounds` has a non-zero origin would silently
    /// misplace the readout by `bounds.minX`, since `ChartGeometry
    /// .readoutOrigin` treats `anchorX` as already living in `bounds`'s space.
    let anchorX: CGFloat

    /// Fills whatever space is proposed, rather than sizing to the readout
    /// box's own dimensions.
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
    /// space" — collapsing it to `0` would starve `placeSubviews` of any real
    /// bounds to clamp against and is exactly how the original bug (a
    /// zero-sized box, see `placeSubviews`'s doc comment) came back in a
    /// different shape. `replacingUnspecifiedDimensions` resolves that by
    /// falling back to the one subview's own preferred size instead of
    /// fabricating zero.
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
        let origin = ChartGeometry.readoutOrigin(atX: anchorX, in: bounds, boxSize: size)
        subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
