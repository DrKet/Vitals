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

/// Offscreen, `glassSurface()` falls back to `.regularMaterial` painted as a
/// flat, fully-opaque grey — confirmed empirically at this value in this
/// harness (see `regionHasSaturatedColor`'s doc comment, which found the same
/// constant from the saturation angle). Stable across every panel, so it
/// works as a fixed comparison colour rather than one re-sampled per render.
let glassPanelMaterialFallback = NSColor(calibratedRed: 35.0 / 255, green: 35.0 / 255, blue: 35.0 / 255, alpha: 1)

/// Like `regionHasContent(in:region:)`, but compares every pixel in `region`
/// against a caller-supplied colour instead of the image's own top-left
/// corner.
///
/// Two things `regionHasContent` cannot tell apart inside a `GlassPanel`,
/// together: its corner-based background is the *page* background, which
/// differs from the panel's own opaque material regardless of what is drawn
/// on top — so every pixel inside a panel already "has content" by that
/// definition (the same problem `regionHasSaturatedColor`'s doc comment
/// describes from the saturation angle). And `regionHasSaturatedColor` itself
/// cannot help either, because the mark this exists to find — `MetricChart`'s
/// axis-maximum label, `.white.opacity(0.45)` text — is neutral grey with no
/// saturation to detect. Neither existing probe fits a low-contrast,
/// non-saturated mark inside a material panel; this is the one that does,
/// by taking the background as a parameter instead of assuming it.
@MainActor
func regionHasContent(in image: RenderedImage, region: CGRect, differingFrom background: NSColor) throws -> Bool {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

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

/// Where a hardware page's primary chart actually paints, inside an
/// `800x700` render — shared by every page's "renders a full page from a
/// live store" test so they all probe the same, empirically-verified spot
/// rather than five independently-guessed rectangles.
///
/// Derived, not guessed: dumping saturated (non-grey) pixel rows from real
/// `renderPNG` output for all five pages showed every one's chart canvas
/// starting at the same `y = 111pt` — identical header + primary-value
/// layout above it, so this holds regardless of which page it is. The
/// `MetricChart` beneath it grows past its `Vitals.Metrics.chartHeight`
/// (132pt) floor to fill leftover space, so its actual rendered height
/// varies by page (207pt measured for CPU's; every hardware page's is now
/// held at or below `Vitals.Metrics.chartMaxHeight` — 220pt — by
/// `HardwarePage`) — but the floor itself is a *guarantee*, so a probe
/// rectangle that stays within `y ∈ [111, 111+132]`
/// is always entirely inside the chart's canvas no matter how much extra
/// room it grows into, and always well short of secondary content
/// (`CoreGrid`, `VolumeBar`) that only ever starts after the chart's actual
/// (grown) bottom.
///
/// `x` is inset from the panel's own content edges (`x ∈ [20, 780]` at this
/// width) to stay clear of the rounded-corner antialiasing; `y` starts a few
/// points below the canvas top for the same reason and stops well inside the
/// guaranteed floor rather than right at its edge.
///
/// Each page's "renders a full page" test picks its sample data so its
/// chart's topmost band sits high in the canvas — see each test's comment —
/// which is what makes one shared, generously-sized rectangle correct for all
/// five without per-page tuning.
///
/// For a fraction series that means a stacked total near 1.0. For an absolute
/// series it takes deliberate choosing: throughput charts no longer hug their
/// own peak. `ChartGeometry.upperBound` rounds an absolute chart's ceiling up
/// to the nearest `m x 10^n` (see `niceUpperBound`), so a reading is drawn at
/// `value / roundedBound` of the height, not at the top — a peak of 3.0
/// against a bound of 5 sits at 60%, well below this rectangle. Pick fixture
/// values whose total lands near a nice bound rather than assuming any
/// non-zero reading reaches the canvas top; that assumption was true before
/// the rounding landed and it broke three page tests when it stopped being.
let chartCanvasProbeRegion = CGRect(x: 40, y: 118, width: 720, height: 85)

/// True when any pixel inside `region` is a saturated (non-grayscale)
/// colour — its channels are not all approximately equal.
///
/// `regionHasContent` above cannot tell chart data from chrome once a view
/// sits inside a `GlassPanel`. Offscreen, `glassSurface()` falls back to
/// `.regularMaterial` painted as a flat, fully-opaque grey (confirmed
/// empirically at RGB(35,35,35) in this harness) that fills the panel
/// whether or not anything is drawn on top of it — so `regionHasContent`,
/// which only asks "does this differ from the corner pixel outside any
/// panel," returns `true` for a panel's bare material alone, before a single
/// band is painted. Every hardware page's chrome (that material, gridlines,
/// `StatRow` text, the disclosure chevron) renders in neutral greys; the
/// *only* saturated colour anywhere on a page comes from a chart's own
/// accent-tinted fill, stroke, or live dot (or `CoreGrid`'s / `VolumeBar`'s
/// accent-filled bars). Asking "is there a non-neutral pixel here" is
/// therefore the discriminator that actually answers "did this page's chart
/// paint its own data" inside a material panel, where a plain
/// difference-from-background check cannot.
///
/// Built on the same bounds-clamping and pixel access as `regionHasContent`
/// rather than a parallel screenshot mechanism — the only difference is what
/// counts as "content".
@MainActor
func regionHasSaturatedColor(
    in image: RenderedImage,
    region: CGRect,
    minimumSpread: CGFloat = 16.0 / 255.0
) throws -> Bool {
    try firstSaturatedColor(in: image, region: region, minimumSpread: minimumSpread) != nil
}

/// The first saturated (non-grayscale) colour found scanning `region`
/// top-to-bottom, left-to-right, or `nil` if the region is entirely neutral
/// grey.
///
/// Used where a test needs to know *which* colour a chart painted — e.g.
/// comparing two pages' charts to prove their accents actually differ —
/// rather than merely that some non-neutral colour exists. See
/// `regionHasSaturatedColor`'s doc comment for why a saturation probe, not a
/// background-difference check, is the correct tool inside a `GlassPanel`.
@MainActor
func firstSaturatedColor(
    in image: RenderedImage,
    region: CGRect,
    minimumSpread: CGFloat = 16.0 / 255.0
) throws -> NSColor? {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let minX = max(Int((region.minX * image.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * image.scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * image.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * image.scale).rounded(.up)), bitmap.pixelsHigh)
    guard minX < maxX, minY < maxY else { return nil }

    for y in minY..<maxY {
        for x in minX..<maxX {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
            if max(r, g, b) - min(r, g, b) > minimumSpread { return color }
        }
    }
    return nil
}

/// `color`'s hue, in the same `0...1` space `NSColor.getHue` reports.
///
/// The unit `regionHasSaturatedColor(in:region:matchingHueOf:)`'s `hues`
/// parameter is compared against, so a caller can hand it a `Vitals.Palette`
/// colour (or anything from `Vitals.seriesColors`) directly rather than
/// re-deriving its hue by hand at every call site.
@MainActor
func hue(of color: Color) -> CGFloat {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    NSColor(color).usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return h
}

/// True when `region` contains a saturated pixel whose hue matches one of
/// `hues` (each in `NSColor`'s `0...1` hue space) within `tolerance`.
///
/// `regionHasSaturatedColor(in:region:)` above only proves *some* non-neutral
/// colour exists in a region — inside a `GlassPanel`, a hardware page's
/// `CoreGrid` or `VolumeBar` satisfies that just as well as its chart does,
/// since both always paint in the page's own lead accent (`colors[0]` of its
/// `Vitals.seriesColors(startingAt:count:)` ramp — the same hue `MetricChart`
/// gives its base band). A page whose chart stopped rendering entirely, but
/// whose `CoreGrid`/`VolumeBar` moved into the probe rectangle once the
/// collapsed layout closed the gap the chart used to occupy, would still
/// "pass" a plain saturation probe — the false pass a senior review found by
/// hand in `CPUPageTests` and `StoragePageTests`: with
/// `HardwarePage.swift`'s `if !series.isEmpty` guard defeated (simulating
/// `series` coming back empty, its real-world failure mode), `CoreGrid` and
/// `VolumeBar` slid up into `chartCanvasProbeRegion` and painted it a
/// saturated colour regardless.
///
/// Restricting the match to hues *other than* a page's lead accent — the
/// higher-index bands only `MetricChart`'s own multi-band stack ever paints,
/// since `CoreGrid`/`VolumeBar` are single-colour — closes that gap: this can
/// only be satisfied by the chart's own data-driven drawing. Verified by
/// hand against both regressions this guards: reverting `MetricChart.swift`'s
/// `drawAreas` to draw nothing, and separately defeating
/// `HardwarePage.swift`'s `if !series.isEmpty` guard, both make every one of
/// the five page-level callers of this fail; restoring either makes all five
/// pass again.
///
/// Hue rather than a raw colour match, for the same reason
/// `PageRenderRegressionTests.differentPagesPaintDifferentChartColours` compares
/// hue rather than RGB distance: a stacked area fill blends a band's colour
/// toward the neutral material behind it at whatever alpha corresponds to a
/// given pixel's height in the chart, which shifts brightness and saturation
/// but preserves hue angle exactly.
@MainActor
func regionHasSaturatedColor(
    in image: RenderedImage,
    region: CGRect,
    matchingHueOf hues: [CGFloat],
    tolerance: CGFloat = 0.05
) throws -> Bool {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let minX = max(Int((region.minX * image.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * image.scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * image.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * image.scale).rounded(.up)), bitmap.pixelsHigh)
    guard minX < maxX, minY < maxY else { return false }

    for y in minY..<maxY {
        for x in minX..<maxX {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
            guard max(r, g, b) - min(r, g, b) > (16.0 / 255.0) else { continue }

            var pixelHue: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            color.getHue(&pixelHue, saturation: &s, brightness: &br, alpha: &a)
            let matches = hues.contains { candidate in
                let raw = abs(candidate - pixelHue)
                return min(raw, 1 - raw) <= tolerance
            }
            if matches { return true }
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

/// The vertical extent, in points, of saturated (non-grayscale) pixels inside
/// `region` — `nil` when the region is entirely neutral.
///
/// `regionHasSaturatedColor` answers "did the chart paint here at all". This
/// answers "how tall is what it painted", which is what a test of the chart's
/// *height* needs. Every hardware page's chrome — the offscreen material fill,
/// gridlines, `StatRow` text, the disclosure chevron — renders in neutral
/// greys (see `regionHasSaturatedColor`'s doc comment), so inside a page's
/// panel the saturated extent is the chart's own drawn height and nothing
/// else.
///
/// Returned in points, not pixels, by dividing through `image.scale` — the
/// same scale the bitmap itself reported, so a 1x and a 2x render give the
/// same answer.
@MainActor
func saturatedRowExtent(
    in image: RenderedImage,
    region: CGRect,
    minimumSpread: CGFloat = 16.0 / 255.0
) throws -> ClosedRange<CGFloat>? {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let minX = max(Int((region.minX * image.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * image.scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * image.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * image.scale).rounded(.up)), bitmap.pixelsHigh)
    guard minX < maxX, minY < maxY else { return nil }

    var top: Int?
    var bottom: Int?
    for y in minY..<maxY {
        for x in minX..<maxX {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
            if max(r, g, b) - min(r, g, b) > minimumSpread {
                if top == nil { top = y }
                bottom = y
                break
            }
        }
    }

    guard let top, let bottom else { return nil }
    return (CGFloat(top) / image.scale)...(CGFloat(bottom) / image.scale)
}

/// The horizontal extent, in points, of saturated (non-grayscale) pixels
/// inside `region` — `nil` when the region is entirely neutral.
///
/// The horizontal twin of `saturatedRowExtent` above, for tests that need to
/// know *where along x* something painted rather than how tall it is —
/// e.g. checking that a readout box landed at the x-position its anchor
/// implies, not merely that it painted somewhere inside a chart. A test that
/// only asks "is there saturated colour in this rectangle" cannot
/// distinguish a box placed correctly from one placed at the wrong x inside
/// the same rectangle, or from one that ignored its anchor entirely and
/// landed at a fixed corner that happens to fall inside the probed region.
/// This answers the stronger question — but what it reports is the *index*
/// of the first and the last pixel column found to contain a saturated
/// pixel, not the drawn content's true left and right edges: the last
/// saturated column's own right-hand edge is one more pixel past
/// `upperBound`, so the true painted width is one pixel wider than
/// `upperBound - lowerBound`. Close enough for every caller here, all of
/// which compare against an independently computed expected position with a
/// multi-point tolerance, but worth knowing before reading this as an exact
/// bounding box.
///
/// Returned in points, not pixels, by dividing through `image.scale` — the
/// same scale the bitmap itself reported, so a 1x and a 2x render give the
/// same answer.
@MainActor
func saturatedColumnExtent(
    in image: RenderedImage,
    region: CGRect,
    minimumSpread: CGFloat = 16.0 / 255.0
) throws -> ClosedRange<CGFloat>? {
    let data = try Data(contentsOf: image.url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        struct DecodeFailure: Error {}
        throw DecodeFailure()
    }

    let minX = max(Int((region.minX * image.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * image.scale).rounded(.up)), bitmap.pixelsWide)
    let minY = max(Int((region.minY * image.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * image.scale).rounded(.up)), bitmap.pixelsHigh)
    guard minX < maxX, minY < maxY else { return nil }

    var left: Int?
    var right: Int?
    for x in minX..<maxX {
        for y in minY..<maxY {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
            if max(r, g, b) - min(r, g, b) > minimumSpread {
                if left == nil { left = x }
                right = x
                break
            }
        }
    }

    guard let left, let right else { return nil }
    return (CGFloat(left) / image.scale)...(CGFloat(right) / image.scale)
}
