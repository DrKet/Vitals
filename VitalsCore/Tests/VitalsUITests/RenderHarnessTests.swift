import AppKit
import SwiftUI
import Testing
@testable import VitalsUI

/// Proves the harness's own scale derivation rather than trusting it by
/// inspection: `renderPNG` no longer assumes a density, so this checks that
/// what it derives actually reproduces the bitmap's real pixel dimensions —
/// on whatever display density this machine happens to have.
@MainActor
@Suite("Render harness")
struct RenderHarnessTests {

    @Test("the derived scale converts the requested logical size into the bitmap's actual pixel size")
    func scaleMatchesBitmapPixelDimensions() throws {
        let size = CGSize(width: 240, height: 140)
        let panel = GlassPanel {
            Text("PROBE").font(Vitals.Typography.label)
        }
        let rendered = try renderPNG(panel, size: size, named: "harness-scale-probe")

        let data = try Data(contentsOf: rendered.url)
        let bitmap = try #require(NSBitmapImageRep(data: data))

        // A real, positive density — not a zero or negative result from a
        // broken computation.
        #expect(rendered.scale > 0)

        // The whole point: `size * scale` must reproduce the bitmap's actual
        // pixel dimensions exactly, whatever this machine's density is. If
        // `renderPNG` ever went back to a hardcoded constant, this would only
        // pass by coincidence on a display matching that constant — this
        // asserts the relationship itself, not a specific number.
        #expect(CGFloat(bitmap.pixelsWide) == (size.width * rendered.scale).rounded())
        #expect(CGFloat(bitmap.pixelsHigh) == (size.height * rendered.scale).rounded())
    }

    @Test("a region probe against a render agrees with the render's own derived scale")
    func regionProbeUsesTheSameScaleAsTheRender() throws {
        // A region covering the whole render must find content exactly when
        // the whole-image blank check would have — which only holds if
        // `regionHasContent` converts the region with the same scale
        // `renderPNG` derived, not a separate assumed constant.
        let size = CGSize(width: 240, height: 140)
        let panel = GlassPanel {
            Text("PROBE").font(Vitals.Typography.label)
        }
        let rendered = try renderPNG(panel, size: size, named: "harness-scale-probe-region")

        let wholeRegion = CGRect(origin: .zero, size: size)
        #expect(try regionHasContent(in: rendered, region: wholeRegion))
    }

    @Test("regionHasContent is vacuous once a view sits on a GlassPanel — the gap regionHasSaturatedColor exists to close")
    func regionHasContentIsVacuousInsideGlassPanel() throws {
        // Documents the actual finding behind `regionHasSaturatedColor`'s doc
        // comment, rather than just asserting it: `glassSurface()`'s offscreen
        // fallback paints a flat, fully-opaque material fill that already
        // differs from the page's own background — so a region entirely
        // inside a `GlassPanel`, with nothing else drawn on top, still reads
        // as "has content" against the harness's background-difference check.
        // A test built on `regionHasContent` alone inside a panel could not
        // have told a working chart from a broken one; this is why the five
        // hardware-page render tests use `regionHasSaturatedColor` instead.
        let size = CGSize(width: 200, height: 200)
        let panel = GlassPanel {
            Color.clear.frame(width: 160, height: 160)
        }
        let rendered = try renderPNG(panel, size: size, named: "harness-glass-vacuity-probe")

        let insidePanelOnly = CGRect(x: 20, y: 20, width: 160, height: 160)
        #expect(try regionHasContent(in: rendered, region: insidePanelOnly))
    }

    @Test("regionHasSaturatedColor finds a genuinely coloured pixel and ignores neutral chrome")
    func regionHasSaturatedColorDistinguishesColourFromGrey() throws {
        let size = CGSize(width: 200, height: 100)
        // Left half neutral grey (stands in for material/gridline chrome),
        // right half a saturated orange (stands in for real chart content).
        let split = HStack(spacing: 0) {
            Color(red: 0.14, green: 0.14, blue: 0.14).frame(width: 100, height: 100)
            Color(red: 1.0, green: 0.55, blue: 0.1).frame(width: 100, height: 100)
        }
        let rendered = try renderPNG(split, size: size, named: "harness-saturation-probe")

        let greySide = CGRect(x: 0, y: 0, width: 90, height: 100)
        let orangeSide = CGRect(x: 110, y: 0, width: 90, height: 100)
        #expect(try !regionHasSaturatedColor(in: rendered, region: greySide))
        #expect(try regionHasSaturatedColor(in: rendered, region: orangeSide))

        let found = try #require(try firstSaturatedColor(in: rendered, region: orangeSide))
        #expect(found.redComponent > found.blueComponent)
    }

    /// Pins `PixelGrid` — which every probe reads through — to the
    /// `NSBitmapImageRep.colorAt` the probes used before it, pixel by pixel.
    /// The render covers every hue sector (a full-spectrum gradient), neutral
    /// greys, and partial alpha, so the component read, the alpha channel and
    /// every branch of the hue formula are each exercised against the
    /// reference rather than assumed equivalent.
    @Test("PixelGrid reads exactly what colorAt reads, including hue, on every pixel")
    func pixelGridMatchesColorAt() throws {
        let size = CGSize(width: 180, height: 90)
        let spectrum = VStack(spacing: 0) {
            LinearGradient(
                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 40)
            HStack(spacing: 0) {
                Color(white: 0.14)
                Color(white: 0.6)
                Color.orange.opacity(0.35)
            }
            .frame(height: 50)
        }
        let rendered = try renderPNG(spectrum, size: size, named: "harness-pixelgrid-equivalence")
        let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: rendered.url)))
        let grid = try PixelGrid(rendered)

        #expect(grid.width == bitmap.pixelsWide)
        #expect(grid.height == bitmap.pixelsHigh)

        var componentMismatches = 0
        var hueMismatches = 0
        var huesCompared = 0
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let reference = try #require(bitmap.colorAt(x: x, y: y))
                let components = grid.components(x, y)
                if abs(components.r - reference.redComponent) > 1e-12
                    || abs(components.g - reference.greenComponent) > 1e-12
                    || abs(components.b - reference.blueComponent) > 1e-12
                    || abs(components.a - reference.alphaComponent) > 1e-12 {
                    componentMismatches += 1
                }
                guard grid.spread(x, y) > 0 else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
                reference.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
                huesCompared += 1
                // Circular: hue is an angle, so 0 and 1 are the same red.
                // `getHue` maps a red whose green equals its blue to 1.0 —
                // its own convention, even for an exact (1, 0, 0) — where
                // `PixelGrid` reports 0.0; the one probe that consumes hue
                // compares circularly, so the two agree wherever it matters.
                let raw = abs(grid.hue(x, y) - h)
                if min(raw, 1 - raw) > 1e-9 { hueMismatches += 1 }
            }
        }
        #expect(componentMismatches == 0)
        #expect(hueMismatches == 0)
        // Non-vacuous: the gradient really did produce saturated pixels.
        #expect(huesCompared > grid.width * 10)
    }
}
