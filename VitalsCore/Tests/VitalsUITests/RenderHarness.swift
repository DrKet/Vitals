import AppKit
import SwiftUI
import Testing

/// Renders a SwiftUI view to a PNG offscreen.
///
/// This exists because verifying a macOS app's appearance normally needs a
/// screen-recording permission that a non-interactive session does not have.
/// `ImageRenderer` needs no permission and no window.
///
/// Caveat worth knowing: these renders verify layout, typography, and chart
/// geometry — never the glass material, which is switched off here and must be
/// judged in the running app.
@MainActor
func renderPNG(
    _ view: some View,
    size: CGSize,
    named name: String
) throws -> URL {
    // Glass is switched off for offscreen capture. `.glassEffect` renders
    // nothing through `ImageRenderer` — not the material, and not its own
    // children either — so every render would be blank and every assertion
    // vacuous. The fallback keeps identical geometry, so layout, typography,
    // and chart drawing are all still verified.
    let content = view
        .environment(\.vitalsGlassEnabled, false)
        .frame(width: size.width, height: size.height)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2

    let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))

    let directory = URL(fileURLWithPath: "/tmp/vitals-render")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(name).png")
    try png.write(to: url)

    // A render that produced a uniformly blank image drew nothing. Asserting
    // only that the file exists would pass for a chart that silently failed to
    // paint, which is exactly the bug these tests exist to catch.
    try #require(isNotBlank(bitmap), "\(name) rendered a uniformly blank image")

    return url
}

/// True when any pixel inside `region` (in the point-space coordinates the
/// view was rendered at, e.g. the `size` passed to `renderPNG`) differs from
/// the image's background colour.
///
/// A narrower complement to `renderPNG`'s whole-image blank check. That check
/// only proves *something* painted somewhere — for a view like a chart, where
/// gridlines paint unconditionally across the full width, "something painted
/// somewhere" is true even if the data-driven drawing (bars, areas) is
/// completely broken. A region probe lets a test assert that a specific area
/// — one gridlines don't reach, or one only a correctly-computed value could
/// reach — has real content.
///
/// Deliberately as simple as `isNotBlank`: still just "does anything differ
/// from the background," scoped to a sub-rectangle. It cannot judge whether
/// content looks *right*, only that some content exists where it must.
@MainActor
func regionHasContent(at url: URL, region: CGRect, scale: CGFloat = 2) throws -> Bool {
    let data = try Data(contentsOf: url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let background = bitmap.colorAt(x: 0, y: 0)
    let minX = max(Int((region.minX * scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * scale).rounded(.up)), bitmap.pixelsHigh)
    guard minX < maxX, minY < maxY else { return false }

    for x in minX..<maxX {
        for y in minY..<maxY {
            if bitmap.colorAt(x: x, y: y) != background { return true }
        }
    }
    return false
}

/// True when the bitmap contains more than one distinct pixel value.
///
/// Deliberately weak: it cannot judge whether a render looks *right*, only that
/// something was drawn. Appearance is judged by opening the PNG.
///
/// Scans every pixel rather than a coarse grid. A fixed 16x16 stride sampled a
/// chart that drew only its three quarter-fraction gridlines at exactly the
/// rows the stride skips (132pt height -> 264px at scale 2, gridlines at rows
/// 66/132/198, none a multiple of the resulting 16px step) — a legitimately
/// non-blank render reported as blank. Full-scan closes that blind spot; it
/// exits on the first difference, so any render with real content anywhere
/// returns near-instantly, and only a truly blank image pays the full cost
/// (well under a second at the sizes these tests render).
private func isNotBlank(_ bitmap: NSBitmapImageRep) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }

    let first = bitmap.colorAt(x: 0, y: 0)
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            if bitmap.colorAt(x: x, y: y) != first { return true }
        }
    }
    return false
}
