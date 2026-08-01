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

    /// Rendered into a canvas WIDER than the chart the box is placed in, with
    /// the surplus left visible.
    ///
    /// This is the whole point of the test and the reason it cannot be
    /// vacuous. If the placement were probed inside a render exactly as wide
    /// as the chart, an overflowing box would be clipped by the image bounds
    /// and the probe would find nothing — passing for the broken code. Giving
    /// the render 200pt of visible surplus means an overflow has somewhere to
    /// land, and the assertion "nothing painted out there" has teeth.
    private func harness(anchorX: CGFloat) -> some View {
        HStack(spacing: 0) {
            ReadoutPlacement(anchorX: anchorX) { box() }
                .frame(width: 600, height: 200)
            Color.clear.frame(width: 200, height: 200)
        }
    }

    @Test("a readout anchored at the right edge stays inside the chart")
    func staysInsideAtRightEdge() throws {
        // 598 of a 600pt-wide chart: two points from the trailing edge, the
        // position that clips in the running app.
        let rendered = try renderPNG(
            harness(anchorX: 598),
            size: CGSize(width: 800, height: 200),
            named: "readout-right-edge"
        )

        // Nothing may paint in the surplus strip beyond the chart.
        let surplus = CGRect(x: 602, y: 0, width: 198, height: 200)
        #expect(try !regionHasSaturatedColor(in: rendered, region: surplus))

        // …and the box must actually have been drawn, or the assertion above
        // passes for a readout that rendered nothing at all.
        let inside = CGRect(x: 0, y: 0, width: 600, height: 200)
        #expect(try regionHasSaturatedColor(in: rendered, region: inside))
    }

    @Test("a readout anchored at the left edge stays inside the chart")
    func staysInsideAtLeftEdge() throws {
        let rendered = try renderPNG(
            harness(anchorX: 2),
            size: CGSize(width: 800, height: 200),
            named: "readout-left-edge"
        )
        let surplus = CGRect(x: 602, y: 0, width: 198, height: 200)
        #expect(try !regionHasSaturatedColor(in: rendered, region: surplus))
        #expect(try regionHasSaturatedColor(in: rendered, region: CGRect(x: 0, y: 0, width: 600, height: 200)))
    }
}
