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

    /// The chart's rect within the render canvas — the same rect `anchorX`
    /// is expressed against below, and (empirically confirmed by a temporary
    /// debug print in `ReadoutPlacement.placeSubviews` while writing this
    /// test) the same rect `ReadoutPlacement` actually receives as `bounds`.
    ///
    /// That equality is not a framework guarantee this test gets for free —
    /// it is exactly finding 4's point. Apple's `Layout` protocol documents
    /// `bounds`'s origin as "not necessarily `(0, 0)`," and this was
    /// confirmed directly here: giving the chart 200pt of leading surplus
    /// (below) makes `placeSubviews` receive `bounds = (200, 0, 600, 200)`,
    /// *not* `(0, 0, 600, 200)` — even though `ReadoutPlacement` is nested
    /// exactly the way `MetricChart` nests it (`GeometryReader` → `ZStack` →
    /// `ReadoutPlacement`, no offsets or extra modifiers). A `GeometryReader`
    /// resetting its own coordinate queries to `.local` does not reset what
    /// the `Layout` protocol hands a nested custom `Layout` — those are two
    /// different mechanisms. Every `anchorX` used below is therefore built
    /// from `chartRect.origin`, not `0`, so it lands in the same coordinate
    /// space this rect — and `bounds` — actually occupy.
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
    /// untouched, independently-tested production formula, computed from the
    /// same `anchorX` and `chartRect` — closes that gap: it fails for any
    /// `placeSubviews` that doesn't actually thread `anchorX` and `bounds`
    /// through to that formula, which is the wiring these tests exist to
    /// guard, not the formula's own maths (that's `ChartScrubberTests`'s
    /// job).
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
        let extent = try #require(
            try saturatedColumnExtent(in: rendered, region: chartRect),
            "no saturated pixels found inside the chart"
        )

        // …and it must be where anchorX implies, not just "somewhere inside".
        let boxSize = try measuredBoxSize()
        let expectedOrigin = ChartGeometry.readoutOrigin(atX: anchorX, in: chartRect, boxSize: boxSize)
        let expectedLeft = expectedOrigin.x
        let expectedRight = expectedLeft + boxSize.width

        // Never float equality: rendering, measuring, and rounding to pixel
        // boundaries each introduce their own slack.
        let tolerance: CGFloat = 3
        #expect(abs(extent.lowerBound - expectedLeft) <= tolerance)
        #expect(abs(extent.upperBound - expectedRight) <= tolerance)
    }

    @Test("a readout anchored at the right edge stays inside the chart, at the position anchorX implies")
    func staysInsideAtRightEdge() throws {
        // 2 points from the chart's own trailing edge — the position that
        // clips in the running app. Expressed against `chartRect`, not `0`;
        // see `chartRect`'s doc comment.
        try assertBoxLandsAtAnchor(anchorX: chartRect.maxX - 2, named: "readout-right-edge")
    }

    @Test("a readout anchored at the left edge stays inside the chart, at the position anchorX implies")
    func staysInsideAtLeftEdge() throws {
        try assertBoxLandsAtAnchor(anchorX: chartRect.minX + 2, named: "readout-left-edge")
    }
}
