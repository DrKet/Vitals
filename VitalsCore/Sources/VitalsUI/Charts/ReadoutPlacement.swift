import SwiftUI

/// Places the crosshair's readout box inside a chart, clamped so it can never
/// overflow.
struct ReadoutPlacement: Layout {
    /// Where on the chart's x-axis the readout is reporting from.
    let anchorX: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
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
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        let origin = ChartGeometry.readoutOrigin(atX: anchorX, in: bounds, boxSize: size)
        subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
