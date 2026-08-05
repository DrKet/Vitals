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
    /// 200pt of leading surplus and 100pt of top surplus makes
    /// `placeSubviews` receive `bounds = (200.0, 100.0, 600.0, 200.0)`, *not*
    /// `(0, 0, 600, 200)` — even though `ReadoutPlacement` is nested exactly
    /// the way `MetricChart` nests it (`GeometryReader` → `ZStack` →
    /// `ReadoutPlacement`, no offsets or extra modifiers). A `GeometryReader`
    /// resetting its own coordinate queries to `.local` does not reset what
    /// the `Layout` protocol hands a nested custom `Layout` — those are two
    /// different mechanisms.
    ///
    /// The top surplus exists for the same reason `bounds.minY` needed
    /// calling out at all: with no vertical surplus, `bounds.minY` is `0` no
    /// matter what, which made `placeSubviews` dropping `+ bounds.minY`
    /// entirely unobservable — `0 == 0` either way regardless of which one
    /// the code actually adds. A senior review reproduced exactly that: with
    /// `+ bounds.minY` deleted from `placeSubviews`, all 3 tests in this file
    /// still passed, because this harness never gave the y-axis anything to
    /// disagree about. Lifting the chart 100pt below a `Color.clear` spacer
    /// gives that translation something to actually do, and gives a dropped
    /// translation somewhere to visibly land — the spacer strip above the
    /// chart — instead of nowhere.
    ///
    /// `MetricChart` computes `anchorX` against its own zero-origin rect
    /// (`CGRect(origin: .zero, size: proxy.size)`), which this harness's
    /// 200pt leading surplus makes different from `chartRect` by exactly
    /// `chartRect.minX` — the same δ production ships with. Every `anchorX`
    /// passed to `harness(anchorX:)` below is therefore chart-LOCAL (`0` at
    /// the chart's own left edge), matching what `MetricChart` actually
    /// feeds `ReadoutPlacement`, and every expected position is computed
    /// against `chartRect` translated by `chartRect.origin` — both `minX`
    /// and `minY` — to match.
    private let chartRect = CGRect(x: 200, y: 100, width: 600, height: 200)

    /// The full render canvas: `chartRect` inset by 200pt of surplus on the
    /// leading side and 200pt on the trailing side horizontally, plus 100pt
    /// of surplus above it vertically.
    ///
    /// No surplus below the chart: a dropped `+ bounds.minY` moves the box
    /// UP, out of `chartRect` and into the space above it — never down — so
    /// only the space above needs somewhere for that escape to land. The
    /// chart's own bottom edge coinciding with the canvas's bottom edge is
    /// harmless for the same reason the original horizontal harness's
    /// missing leading surplus was not: there, a leftward escape had nowhere
    /// to land and read as "inside" by every probe; here, an escape that
    /// only ever goes up is still fully covered by the surplus that exists.
    private var canvasSize: CGSize {
        CGSize(width: chartRect.minX + chartRect.width + 200, height: chartRect.minY + chartRect.height)
    }

    /// Rendered into a canvas WIDER than the chart on BOTH sides and TALLER
    /// above it, with all of that surplus left visible.
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
    /// to test with once there's a leading sibling in the picture. The outer
    /// `VStack` and its top `Color.clear` spacer are a harness-only device
    /// with no analogue in `MetricChart` — they exist purely to give
    /// `chartRect` (and therefore `bounds`) a non-zero `minY`, the same way
    /// the leading `Color.clear` gives it a non-zero `minX`, so the
    /// y-translation is exercised the same way the x-translation already is.
    private func harness(anchorX: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: chartRect.minY)
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
    /// A prior version of this test rendered through `.fixedSize()` (both
    /// axes) and asserted only that the CHILD box rendered at its own full
    /// size. That assertion cannot fail: `placeSubviews` always measures the
    /// child independently via `subview.sizeThatFits(.unspecified)` and
    /// proposes exactly that size back to it, so the child renders
    /// identically whether `sizeThatFits`'s fallback is
    /// `replacingUnspecifiedDimensions` or a broken `?? 0` — confirmed by
    /// reintroducing `?? 0` and watching all 3 tests in this file stay
    /// green. What actually differs under `?? 0` is `ReadoutPlacement`'s OWN
    /// reported size — the `Layout`'s footprint, not its child's paint — and
    /// nothing was watching that.
    ///
    /// This version makes that footprint observable with a `.background(...)`
    /// applied to `ReadoutPlacement` ITSELF (not the child): a `.background`
    /// is always sized to match the modified view's own reported size, so it
    /// renders at whatever `sizeThatFits` says this `Layout` is, independent
    /// of whatever the child underneath happens to paint.
    ///
    /// Only `vertical` is fixed (`.fixedSize(horizontal: false, vertical:
    /// true)`), not both axes — confirmed via a temporary debug print added
    /// to `sizeThatFits` while writing this test to print `proposal=(width,
    /// height)`, which showed `proposal=Optional(400.0),nil`: width stays
    /// whatever the surrounding `.frame(width: 400, ...)` proposes, only
    /// height is forced to `nil`. Fixing both axes (the prior version's
    /// approach) would resolve the box to its own ideal size on both axes
    /// under the correct implementation, making `ReadoutPlacement`'s
    /// reported footprint and the child's rendered rect IDENTICAL — same
    /// origin, same size — which would hide the background entirely behind
    /// the opaque child with no gap for it to show through, correct or not.
    /// Leaving width free instead gives a correctly-resolved footprint that
    /// is much wider (400pt, the ambient frame) than the child's own ideal
    /// width (~100pt, `measuredBoxSize()`), opening a wide gap on either
    /// side of the box where only the background — never the child — can
    /// paint.
    @Test("resolves an unspecified proposal to the readout box's own size instead of collapsing to zero")
    func handlesUnspecifiedProposal() throws {
        let canvas = CGSize(width: 400, height: 200)

        // Distinct from `box()`'s own `Vitals.Palette.legibilityAccent`
        // fill — not because the assertions below match on hue, but so a
        // person inspecting `readout-unspecified-proposal.png` by eye can
        // tell the `Layout`'s own background apart from its child's.
        let backgroundAccent = Vitals.Palette.cpu

        let rendered = try renderPNG(
            ReadoutPlacement(anchorX: 2) { box() }
                .background(backgroundAccent)
                .fixedSize(horizontal: false, vertical: true),
            size: canvas,
            named: "readout-unspecified-proposal"
        )

        // The child box paints regardless of `sizeThatFits`'s fallback (see
        // this test's doc comment), so its mere presence proves nothing. What
        // must be checked is `ReadoutPlacement`'s OWN reported size, made
        // observable as the `.background` above: correctly resolved, it
        // spans (approximately) the full 400pt the ambient frame proposes.
        // Collapsed by `?? 0`, its height goes to zero — a zero-height rect
        // paints no pixels at all — leaving only the child box's own narrow
        // ~100pt width as the widest saturated span anywhere in the render.
        let region = CGRect(origin: .zero, size: canvas)
        let columns = try #require(
            try saturatedColumnExtent(in: rendered, region: region),
            "no saturated pixels found — an unspecified proposal collapsed the box to nothing"
        )
        let measuredWidth = columns.upperBound - columns.lowerBound

        // Same 3pt tolerance as `assertBoxLandsAtAnchor`, for the same
        // reason: rendering, measuring, and pixel rounding each introduce
        // their own slack, and float equality is banned.
        let tolerance: CGFloat = 3

        // The box's own ideal width — measured independently, the same way
        // `assertBoxLandsAtAnchor` measures it, rather than hard-coded — so
        // the sanity check below cannot be fooled by a font-metrics change
        // that happens to widen the box.
        let boxSize = try measuredBoxSize()

        // Sanity check first: if the child alone could satisfy the width
        // assertion below, that assertion would prove nothing about the
        // background's presence. The canvas must be meaningfully wider than
        // the child box for the real assertion to mean what it claims.
        #expect(canvas.width - boxSize.width > tolerance * 2)

        // The real assertion: the measured width must be close to the FULL
        // canvas width, not merely "wider than the box". If the background
        // is absent (the `?? 0` regression), the measured width collapses to
        // the child's own ~100pt and this fails outright — it does not
        // merely report a slightly-off size.
        #expect(abs(measuredWidth - canvas.width) <= tolerance)
    }
}
