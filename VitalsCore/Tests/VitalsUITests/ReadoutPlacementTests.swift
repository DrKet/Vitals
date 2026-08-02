import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Readout placement")
struct ReadoutPlacementTests {

    /// The readout box, styled the way `MetricChart` styles it but with an
    /// opaque saturated fill so the probe can find it. Neutral chrome is
    /// invisible to `regionHasSaturatedColor`; a magenta box is not.
    private func box() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("24s ago")
            Text("Down  0.01 MB/s")
            Text("Up  0.10 MB/s")
        }
        .font(Vitals.Typography.label)
        .padding(6)
        .background(Vitals.Palette.legibilityAccent)
    }

    /// The box's own rendered size, measured by rendering it alone into a
    /// canvas comfortably larger than it in both dimensions.
    ///
    /// The position assertions below need to know how wide the box is to
    /// predict where its edges should land. Hard-coding that width would be
    /// exactly the kind of fabricated number this project's `?? 0` rule
    /// exists to prevent: the box's actual pixel size depends on font
    /// metrics this test doesn't control, so a baked-in constant could
    /// quietly drift out of sync with what SwiftUI actually draws and start
    /// asserting against a size that no longer exists. Measuring it here
    /// keeps the expected-position maths correct regardless of what that
    /// size turns out to be.
    private func measuredBoxSize() throws -> CGSize {
        let canvas = CGSize(width: 400, height: 200)
        let rendered = try renderPNG(box(), size: canvas, named: "readout-box-size-probe")
        let region = CGRect(origin: .zero, size: canvas)
        let columns = try #require(
            try saturatedColumnExtent(in: rendered, region: region),
            "box render painted no saturated pixels"
        )
        let rows = try #require(
            try saturatedRowExtent(in: rendered, region: region),
            "box render painted no saturated pixels"
        )
        return CGSize(
            width: columns.upperBound - columns.lowerBound,
            height: rows.upperBound - rows.lowerBound
        )
    }

    /// The chart's rect within the render canvas — the rect `placeSubviews`
    /// actually receives as `bounds` (empirically confirmed by a temporary
    /// debug print in `ReadoutPlacement.placeSubviews` while writing this
    /// test), NOT the rect `anchorX` is expressed against below.
    ///
    /// Those being different rects is exactly finding 4's point. Apple's
    /// `Layout` protocol documents `bounds`'s origin as "not necessarily
    /// `(0, 0)`," and this was confirmed directly here: giving the chart
    /// 200pt of leading surplus (below) makes `placeSubviews` receive
    /// `bounds = (200, 0, 600, 200)`, *not* `(0, 0, 600, 200)` — even though
    /// `ReadoutPlacement` is nested exactly the way `MetricChart` nests it
    /// (`GeometryReader` → `ZStack` → `ReadoutPlacement`, no offsets or extra
    /// modifiers). A `GeometryReader` resetting its own coordinate queries to
    /// `.local` does not reset what the `Layout` protocol hands a nested
    /// custom `Layout` — those are two different mechanisms.
    ///
    /// `MetricChart` computes `anchorX` against its own zero-origin rect
    /// (`CGRect(origin: .zero, size: proxy.size)`), which this harness's
    /// 200pt leading surplus makes different from `chartRect` by exactly
    /// `chartRect.minX` — the same δ production ships with. Every `anchorX`
    /// passed to `harness(anchorX:)` below is therefore chart-LOCAL (`0` at
    /// the chart's own left edge), matching what `MetricChart` actually
    /// feeds `ReadoutPlacement`, and every expected position is computed
    /// against `chartRect` translated by `chartRect.minX` to match.
    private let chartRect = CGRect(x: 200, y: 0, width: 600, height: 200)

    /// The full render canvas: `chartRect` inset by 200pt of surplus on the
    /// leading side and 200pt on the trailing side.
    private var canvasSize: CGSize {
        CGSize(width: chartRect.minX + chartRect.width + 200, height: chartRect.height)
    }

    /// Rendered into a canvas WIDER than the chart on BOTH sides, with the
    /// surplus on each side left visible.
    ///
    /// Surplus on only the trailing side — this harness's original shape —
    /// made `staysInsideAtLeftEdge` structurally unable to fail: a box placed
    /// off the LEFT edge at a negative x has nothing but the hosting view's
    /// own bounds to be clipped against, and still shows as "inside" every
    /// region this file probed. It passed against a deliberately broken
    /// implementation, which is exactly what a senior review caught. Surplus
    /// on both sides gives a leftward escape and a rightward escape each
    /// somewhere to land, so both tests can actually catch what they claim
    /// to.
    ///
    /// Nested `GeometryReader` → `ZStack` → `ReadoutPlacement`, matching
    /// `MetricChart.body` exactly — see `chartRect`'s doc comment for why
    /// that nesting shape still doesn't make `anchorX == 0` the right value
    /// to test with once there's a leading sibling in the picture.
    private func harness(anchorX: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: chartRect.minX, height: chartRect.height)
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    ReadoutPlacement(anchorX: anchorX) { box() }
                }
            }
            .frame(width: chartRect.width, height: chartRect.height)
            Color.clear.frame(
                width: canvasSize.width - chartRect.minX - chartRect.width,
                height: chartRect.height
            )
        }
    }

    /// Asserts that a render of `harness(anchorX:)` keeps the box inside the
    /// chart and places it exactly where `anchorX` says it should be.
    ///
    /// The two overflow checks alone were never enough — a `placeSubviews`
    /// that ignored `anchorX` and placed at a fixed corner (`bounds.origin`)
    /// passes them just as well as a correct one, since "nowhere in the
    /// surplus" is also true of a box stuck in a corner. Comparing the box's
    /// measured edges against `ChartGeometry.readoutOrigin` — the same,
    /// untouched, independently-tested production formula, computed from a
    /// zero-origin copy of `chartRect` (matching what `anchorX` is expressed
    /// against) and then translated by `chartRect.origin` — closes that gap:
    /// it fails for any `placeSubviews` that doesn't actually reconcile
    /// `anchorX`'s coordinate space with `bounds`'s, which is the wiring
    /// these tests exist to guard, not the formula's own maths (that's
    /// `ChartScrubberTests`'s job).
    ///
    /// `anchorX` here is chart-LOCAL — expressed against `CGRect(origin:
    /// .zero, size: chartRect.size)`, exactly as `MetricChart` computes it —
    /// not against `chartRect` itself. See `chartRect`'s doc comment for why
    /// that distinction, and this harness's 200pt leading surplus, are what
    /// make this test exercise the δ ≠ 0 case that was shipping broken.
    private func assertBoxLandsAtAnchor(anchorX: CGFloat, named name: String) throws {
        let rendered = try renderPNG(
            harness(anchorX: anchorX),
            size: canvasSize,
            named: name
        )

        // Nothing may paint in either surplus strip beyond the chart.
        let leadingSurplus = CGRect(x: 0, y: 0, width: chartRect.minX, height: canvasSize.height)
        let trailingSurplus = CGRect(
            x: chartRect.maxX,
            y: 0,
            width: canvasSize.width - chartRect.maxX,
            height: canvasSize.height
        )
        #expect(try !regionHasSaturatedColor(in: rendered, region: leadingSurplus))
        #expect(try !regionHasSaturatedColor(in: rendered, region: trailingSurplus))

        // The box must actually have been drawn inside the chart, or the
        // checks above pass for a readout that rendered nothing at all.
        let columns = try #require(
            try saturatedColumnExtent(in: rendered, region: chartRect),
            "no saturated pixels found inside the chart"
        )
        let rows = try #require(
            try saturatedRowExtent(in: rendered, region: chartRect),
            "no saturated pixels found inside the chart"
        )

        // …and it must be where anchorX implies, not just "somewhere inside".
        // `readoutOrigin` is computed against a zero-origin rect the same
        // size as `chartRect` — matching the space `anchorX` is expressed in
        // — then translated back into canvas space by `chartRect.origin`,
        // the same translation `placeSubviews` now performs internally.
        let boxSize = try measuredBoxSize()
        let localRect = CGRect(origin: .zero, size: chartRect.size)
        let localOrigin = ChartGeometry.readoutOrigin(atX: anchorX, in: localRect, boxSize: boxSize)
        let expectedOrigin = CGPoint(
            x: localOrigin.x + chartRect.minX,
            y: localOrigin.y + chartRect.minY
        )
        let expectedLeft = expectedOrigin.x
        let expectedRight = expectedLeft + boxSize.width
        let expectedTop = expectedOrigin.y
        let expectedBottom = expectedTop + boxSize.height

        // Never float equality: rendering, measuring, and rounding to pixel
        // boundaries each introduce their own slack. 3pt stays well under the
        // smallest constant in the formula under test — `readoutOrigin`'s 8pt
        // margin — while comfortably covering the ~0 measurement error this
        // harness actually exhibits.
        let tolerance: CGFloat = 3
        #expect(abs(columns.lowerBound - expectedLeft) <= tolerance)
        #expect(abs(columns.upperBound - expectedRight) <= tolerance)
        #expect(abs(rows.lowerBound - expectedTop) <= tolerance)
        #expect(abs(rows.upperBound - expectedBottom) <= tolerance)
    }

    @Test("a readout anchored at the right edge stays inside the chart, at the position anchorX implies")
    func staysInsideAtRightEdge() throws {
        // 2 points from the chart's own trailing edge, in chart-LOCAL space —
        // the position that clips in the running app. See `chartRect`'s and
        // `assertBoxLandsAtAnchor`'s doc comments for why this is
        // `chartRect.width - 2`, not `chartRect.maxX - 2`.
        try assertBoxLandsAtAnchor(anchorX: chartRect.width - 2, named: "readout-right-edge")
    }

    @Test("a readout anchored at the left edge stays inside the chart, at the position anchorX implies")
    func staysInsideAtLeftEdge() throws {
        // 2 points from the chart's own leading edge, in chart-LOCAL space —
        // i.e. `2`, not `chartRect.minX + 2`. See `chartRect`'s doc comment.
        try assertBoxLandsAtAnchor(anchorX: 2, named: "readout-left-edge")
    }

    /// `sizeThatFits` only exercises its `replacingUnspecifiedDimensions`
    /// branch (see its doc comment) when SwiftUI actually proposes `nil` in
    /// a dimension — every other test in this file renders through
    /// `renderPNG`'s outer `.frame(width:height:)`, which proposes a
    /// concrete size straight through to `ReadoutPlacement`, so none of them
    /// take this path.
    ///
    /// `.fixedSize()` is confirmed (via a temporary debug print added to
    /// `sizeThatFits` and `placeSubviews` while writing this test, then
    /// removed) to override that outer `.frame` and force
    /// `ProposedViewSize(width: nil, height: nil)` through to this layout —
    /// `sizeThatFits` printed `proposal=nil,nil`, and the following
    /// `placeSubviews` printed `bounds=(0.0, 0.0, 100.5, 58.0)`, exactly the
    /// box's own measured ideal size, confirming `bounds` really was
    /// resolved from the box's `sizeThatFits(.unspecified)` fallback rather
    /// than from any size this test proposed.
    @Test("resolves an unspecified proposal to the readout box's own size instead of collapsing to zero")
    func handlesUnspecifiedProposal() throws {
        let canvas = CGSize(width: 400, height: 200)
        let rendered = try renderPNG(
            ReadoutPlacement(anchorX: 2) { box() }.fixedSize(),
            size: canvas,
            named: "readout-unspecified-proposal"
        )

        // If `replacingUnspecifiedDimensions`'s fallback were ever replaced
        // with `?? 0` (the exact defect this project's `?? 0` rule exists to
        // prevent), `bounds` would collapse to a zero-sized rect and nothing
        // would paint at all.
        let boxSize = try measuredBoxSize()
        let region = CGRect(origin: .zero, size: canvas)
        let columns = try #require(
            try saturatedColumnExtent(in: rendered, region: region),
            "no saturated pixels found — an unspecified proposal collapsed the box to nothing"
        )
        let rows = try #require(
            try saturatedRowExtent(in: rendered, region: region),
            "no saturated pixels found — an unspecified proposal collapsed the box to nothing"
        )

        // The box must render at its own full, un-squashed size — proving
        // `bounds` really was resolved to the box's ideal size, not to some
        // incidental non-zero fallback that happens to still paint something.
        let tolerance: CGFloat = 3
        #expect(abs((columns.upperBound - columns.lowerBound) - boxSize.width) <= tolerance)
        #expect(abs((rows.upperBound - rows.lowerBound) - boxSize.height) <= tolerance)
    }
}
