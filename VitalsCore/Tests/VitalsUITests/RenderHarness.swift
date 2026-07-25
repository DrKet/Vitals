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

/// True when the bitmap contains more than one distinct pixel value.
///
/// Deliberately weak: it cannot judge whether a render looks *right*, only that
/// something was drawn. Appearance is judged by opening the PNG.
private func isNotBlank(_ bitmap: NSBitmapImageRep) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }

    let first = bitmap.colorAt(x: 0, y: 0)
    let stepX = max(bitmap.pixelsWide / 16, 1)
    let stepY = max(bitmap.pixelsHigh / 16, 1)

    for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            if bitmap.colorAt(x: x, y: y) != first { return true }
        }
    }
    return false
}
