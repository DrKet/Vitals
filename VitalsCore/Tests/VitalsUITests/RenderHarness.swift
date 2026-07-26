import AppKit
import SwiftUI
import Testing

/// Renders a SwiftUI view to a PNG offscreen.
///
/// Requires a GUI login session (a WindowServer connection): the view is
/// hosted in a real, off-screen-positioned `NSWindow`, because `ImageRenderer`
/// cannot render `ScrollView`-rooted views (reliably blank on this toolchain —
/// macOS 26.2, Swift 6.3.3 — reproduced with a bare `ScrollView { Text(...) }`
/// in isolation) and because `.glassEffect` renders nothing at all when drawn
/// offscreen either way. In a non-interactive session with no WindowServer
/// (e.g. SSH-only CI), there is nothing for the `NSWindow` to connect to and
/// this call fails — a requirement the old `ImageRenderer`-only
/// implementation did not have, since it needed no window at all.
///
/// Caveat worth knowing: these renders verify layout, typography, and chart
/// geometry — never the glass material, which is switched off here and must be
/// judged in the running app.
@MainActor
func renderPNG(
    _ view: some View,
    size: CGSize,
    named name: String
) throws -> RenderedImage {
    // Glass is switched off for offscreen capture. `.glassEffect` renders
    // nothing offscreen — not the material, and not its own children either —
    // so every render would be blank and every assertion vacuous. The
    // fallback keeps identical geometry, so layout, typography, and chart
    // drawing are all still verified.
    let content = view
        .environment(\.vitalsGlassEnabled, false)
        .frame(width: size.width, height: size.height)

    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)

    // `.borderless` and a frame far outside any display's bounds: a real
    // window (so AppKit-backed content like `NSScrollView` actually lays
    // out and paints) that never appears on screen or steals focus.
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    defer { window.orderOut(nil) }

    let bitmap = try #require(
        hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
        "could not create a bitmap rep for \(name)"
    )
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))

    let directory = URL(fileURLWithPath: "/tmp/vitals-render")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(name).png")
    try png.write(to: url)

    // A render that produced a uniformly blank image drew nothing. Asserting
    // only that the file exists would pass for a chart that silently failed to
    // paint, which is exactly the bug these tests exist to catch.
    try #require(isNotBlank(bitmap), "\(name) rendered a uniformly blank image")

    // Derived from the bitmap itself rather than assumed: `cacheDisplay`
    // inherits its pixel density from the window's `backingScaleFactor`
    // (ultimately `NSScreen.main`), which is 1x, 2x, or unavailable entirely
    // depending on the machine. Computing it as pixels-per-point of the
    // actual bitmap means a 1x, 2x, or any-x render is always self-consistent
    // — there is no separate constant that could disagree with it.
    let scale = CGFloat(bitmap.pixelsWide) / size.width

    return RenderedImage(url: url, scale: scale)
}

/// A PNG rendered by `renderPNG`, paired with the pixel scale it was actually
/// rendered at.
///
/// Carrying the scale alongside the URL — rather than letting callers assume
/// one — is what makes `regionHasContent` agree with `renderPNG` by
/// construction: there is no second place a density constant could drift out
/// of sync with the bitmap it describes.
struct RenderedImage: Sendable {
    let url: URL
    let scale: CGFloat
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
///
/// Takes the whole `RenderedImage` rather than a bare `URL` plus a scale
/// parameter: pairing the file with the scale it was actually rendered at
/// forecloses passing a scale from a different render (or a guessed
/// constant) by mistake.
@MainActor
func regionHasContent(in image: RenderedImage, region: CGRect) throws -> Bool {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let background = bitmap.colorAt(x: 0, y: 0)
    let minX = max(Int((region.minX * image.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * image.scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * image.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * image.scale).rounded(.up)), bitmap.pixelsHigh)
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
