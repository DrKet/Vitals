import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Thermometer strip")
struct ThermometerStripTests {

    @Test("the marker sits proportionally within the fixed domain")
    func markerFractionIsProportional() {
        #expect(abs(ThermometerStrip.markerFraction(for: 20) - 0.0) < 1e-9)
        #expect(abs(ThermometerStrip.markerFraction(for: 60) - 0.5) < 1e-9)
        #expect(abs(ThermometerStrip.markerFraction(for: 100) - 1.0) < 1e-9)
    }

    /// A reading outside the display scale is clamped, not extrapolated — the
    /// marker must stay on the track rather than being drawn outside it.
    @Test("readings outside the domain clamp to its ends")
    func markerFractionClamps() {
        #expect(abs(ThermometerStrip.markerFraction(for: -40) - 0.0) < 1e-9)
        #expect(abs(ThermometerStrip.markerFraction(for: 400) - 1.0) < 1e-9)
    }

    /// `regionHasContent` (diff-from-the-image's-own-corner-pixel) is the
    /// wrong probe for this: the track's gradient is opaque and spans the
    /// full width unconditionally, so *any* x-position in the track differs
    /// from the corner reference whether or not a marker is drawn on top —
    /// confirmed by running this test with the original `regionHasContent`
    /// version, which fails even against a correct implementation (see
    /// `task-7-report.md`). `regionHasPixelBrighterThan` discriminates
    /// instead: measured directly in this harness, the track's own colour in
    /// this band tops out around brightness 0.55–0.6 (an interpolated point
    /// on a ramp whose channels are deliberately kept under 0.7, precisely so
    /// this probe can tell it apart from the marker), while the white marker
    /// reaches ~1.0. 0.8 sits with wide margin between the two.
    @Test("a strip with a reading paints its marker")
    func stripWithReadingPaintsMarker() throws {
        let rendered = try renderPNG(
            ThermometerStrip(celsius: 38.8).frame(width: 400, height: 40),
            size: CGSize(width: 400, height: 40), named: "thermometer-with-reading"
        )
        // 38.8 °C is 23.5% along a 20–100 track.
        #expect(try regionHasPixelBrighterThan(
            in: rendered, region: CGRect(x: 84, y: 0, width: 20, height: 40), threshold: 0.8
        ))
    }

    /// An unmeasurable value must not place a marker at 20 °C, which is what
    /// treating `nil` as zero would look like. See `stripWithReadingPaintsMarker`
    /// for why brightness, not `regionHasContent`, is the probe that can tell.
    ///
    /// The "no marker" half scans the *entire* track width, not the narrow
    /// band `stripWithReadingPaintsMarker` checks. That band is anchored to
    /// where 38.8 °C's marker belongs; a `celsius ?? 0` bug clamps to the
    /// domain floor and draws its marker at the opposite edge (x≈0) instead
    /// — confirmed by injecting exactly that bug, which left this test green
    /// when it only checked the narrow band (see `task-7-report.md`). The
    /// full-width scan is what actually verifies "no marker anywhere",
    /// which is the invariant this test's own doc comment claims to guard.
    @Test("a strip with no reading paints no marker")
    func stripWithoutReadingPaintsNoMarker() throws {
        let with = try renderPNG(
            ThermometerStrip(celsius: 38.8).frame(width: 400, height: 40),
            size: CGSize(width: 400, height: 40), named: "thermometer-marker-present"
        )
        let without = try renderPNG(
            ThermometerStrip(celsius: nil).frame(width: 400, height: 40),
            size: CGSize(width: 400, height: 40), named: "thermometer-marker-absent"
        )
        let markerBand = CGRect(x: 84, y: 0, width: 20, height: 40)
        let fullTrack = CGRect(x: 0, y: 0, width: 400, height: 40)
        #expect(try regionHasPixelBrighterThan(in: with, region: markerBand, threshold: 0.8))
        #expect(try !regionHasPixelBrighterThan(in: without, region: fullTrack, threshold: 0.8))
    }
}
