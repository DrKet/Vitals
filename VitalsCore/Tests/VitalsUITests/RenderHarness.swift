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
    try #require(try isNotBlank(bitmap), "\(name) rendered a uniformly blank image")

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
/// **Probe placement matters.** `renderPNG` writes PNGs with UNPREMULTIPLIED
/// colour, so a pixel at alpha ~0.01 still stores full-strength RGB. This
/// function and `regionHasSaturatedColor` both read components without
/// weighting by alpha, so both can "see" pixels that are invisible on screen —
/// most notably where a chart's area gradient has faded almost to nothing near
/// the baseline. Two assertions on this project passed against a deliberately
/// broken implementation for exactly that reason. Probe away from a gradient's
/// fade edge, or use `regionHasPixelBrighterThan`, which does weight by alpha.
///
@MainActor
func regionHasContent(in image: RenderedImage, region: CGRect) throws -> Bool {
    let grid = try PixelGrid(image)
    let background = grid.pixel(0, 0)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return false }

    for x in xs {
        for y in ys {
            if grid.pixel(x, y) != background { return true }
        }
    }
    return false
}

/// A decoded `renderPNG` image, read straight from its bytes.
///
/// Every probe in this file reads pixels through this rather than
/// `NSBitmapImageRep.colorAt(x:y:)`, which builds an `NSColor` per pixel:
/// one pass over a full-page render took ~5 s in a debug build. The probes
/// run on the main actor, so a few of them back to back blocked it for ~8 s
/// and starved every main-actor `waitUntil` in the parallel suite — the
/// `MetricsStoreTests` failure long written off as machine load. Reading
/// bytes is the same measurement at a fraction of the cost: for the format
/// `renderPNG` writes, `colorAt` returns exactly `byte / 255` for every
/// component (verified over every pixel of a full-page render, and pinned by
/// `RenderHarnessTests.pixelGridMatchesColorAt`).
///
/// Accepts only that format — 8-bit, four interleaved samples, straight
/// (unpremultiplied) alpha last — and throws on anything else rather than
/// misreading it.
struct PixelGrid {
    struct Pixel: Equatable {
        let r, g, b, a: UInt8
    }

    let width: Int
    let height: Int
    private let storage: Storage
    private let bytesPerRow: Int

    /// The copied pixel bytes, read through a raw pointer: the probes run in
    /// debug builds, where `Array`'s checked subscript made even byte reads
    /// cost ~1 s per full-page scan. Owned here and freed with the grid.
    private final class Storage {
        let base: UnsafeMutablePointer<UInt8>
        init(copying source: UnsafePointer<UInt8>, count: Int) {
            base = .allocate(capacity: count)
            base.initialize(from: source, count: count)
        }
        deinit { base.deallocate() }
    }
    private let bitmap: NSBitmapImageRep

    init(_ image: RenderedImage) throws {
        let data = try Data(contentsOf: image.url)
        guard let bitmap = NSBitmapImageRep(data: data) else {
            struct DecodeFailure: Error {}
            throw DecodeFailure()
        }
        try self.init(bitmap)
    }

    init(_ bitmap: NSBitmapImageRep) throws {
        guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4, bitmap.bitsPerPixel == 32,
              !bitmap.isPlanar, bitmap.hasAlpha,
              // Exactly the verified format: straight alpha last, and no
              // endianness, float or alpha-first flags on top of it.
              bitmap.bitmapFormat == .alphaNonpremultiplied,
              let base = bitmap.bitmapData
        else {
            struct UnsupportedFormat: Error, CustomStringConvertible {
                let description: String
            }
            throw UnsupportedFormat(description:
                "PixelGrid reads only 8-bit interleaved RGBA with straight alpha last; got "
                    + "\(bitmap.bitsPerSample) bits/sample, \(bitmap.samplesPerPixel) samples, "
                    + "format \(bitmap.bitmapFormat.rawValue), planar \(bitmap.isPlanar)")
        }
        self.width = bitmap.pixelsWide
        self.height = bitmap.pixelsHigh
        self.bytesPerRow = bitmap.bytesPerRow
        self.storage = Storage(copying: base, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        self.bitmap = bitmap
    }

    func pixel(_ x: Int, _ y: Int) -> Pixel {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
        let p = storage.base + (y * bytesPerRow + x * 4)
        return Pixel(r: p[0], g: p[1], b: p[2], a: p[3])
    }

    /// The pixel's components in `0...1`, computed exactly as `colorAt`
    /// reports them (`byte / 255`), so the float arithmetic each probe does on
    /// them is unchanged.
    func components(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let p = pixel(x, y)
        return (CGFloat(p.r) / 255, CGFloat(p.g) / 255, CGFloat(p.b) / 255, CGFloat(p.a) / 255)
    }

    /// `max(r, g, b) - min(r, g, b)` on the `0...1` components — the probes'
    /// saturation measure, with the same arithmetic as before.
    ///
    /// Max and min are taken on the bytes, then converted: `byte / 255` is
    /// exact and monotonic, so this is bit-identical to converting first —
    /// and it skips building the components on the hot path.
    func spread(_ x: Int, _ y: Int) -> CGFloat {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
        let p = storage.base + (y * bytesPerRow + x * 4)
        let (r, g, b) = (p[0], p[1], p[2])
        return CGFloat(max(r, g, b)) / 255 - CGFloat(min(r, g, b)) / 255
    }

    /// `spread(x, y) > limit`, answered in advance for every (max byte, min
    /// byte) pair with the identical float expression — so a scan does integer
    /// work and a lookup per pixel, and still gives bit-for-bit the answer the
    /// per-pixel definition would.
    struct SpreadThreshold {
        fileprivate let exceeds: [Bool]   // index: maxByte * 256 + minByte

        init(_ limit: CGFloat) {
            var table = [Bool](repeating: false, count: 256 * 256)
            for high in 0..<256 {
                for low in 0...high {
                    table[high * 256 + low] = CGFloat(high) / 255 - CGFloat(low) / 255 > limit
                }
            }
            exceeds = table
        }
    }

    /// The first `x` in `xs` on row `y` whose spread exceeds `threshold`, or
    /// `nil`. The extent and first-colour probes' hot loop: most rows of a
    /// page hold no colour and are read end to end, so this walks raw bytes
    /// instead of calling `spread` per pixel.
    func firstSaturatedX(inRow y: Int, _ xs: Range<Int>, _ threshold: SpreadThreshold) -> Int? {
        precondition(y >= 0 && y < height && xs.lowerBound >= 0 && xs.upperBound <= width)
        return threshold.exceeds.withUnsafeBufferPointer { table in
            var p = storage.base + (y * bytesPerRow + xs.lowerBound * 4)
            var x = xs.lowerBound
            while x < xs.upperBound {
                let (r, g, b) = (p[0], p[1], p[2])
                if table[Int(max(r, g, b)) &* 256 &+ Int(min(r, g, b))] { return x }
                p += 4
                x += 1
            }
            return nil
        }
    }

    /// The column twin of `firstSaturatedX(inRow:_:_:)`.
    func firstSaturatedY(inColumn x: Int, _ ys: Range<Int>, _ threshold: SpreadThreshold) -> Int? {
        precondition(x >= 0 && x < width && ys.lowerBound >= 0 && ys.upperBound <= height)
        return threshold.exceeds.withUnsafeBufferPointer { table in
            var p = storage.base + (ys.lowerBound * bytesPerRow + x * 4)
            var y = ys.lowerBound
            while y < ys.upperBound {
                let (r, g, b) = (p[0], p[1], p[2])
                if table[Int(max(r, g, b)) &* 256 &+ Int(min(r, g, b))] { return y }
                p += bytesPerRow
                y += 1
            }
            return nil
        }
    }

    /// The pixel's hue in `NSColor.getHue`'s `0...1` space (0 for a grey).
    /// Which channel is the maximum is decided on the bytes, so there is no
    /// float equality in the branch.
    func hue(_ x: Int, _ y: Int) -> CGFloat {
        let p = pixel(x, y)
        let c = components(x, y)
        let delta = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
        guard delta > 0 else { return 0 }
        var sector: CGFloat
        if p.r >= p.g && p.r >= p.b {
            sector = (c.g - c.b) / delta
            if sector < 0 { sector += 6 }
        } else if p.g >= p.b {
            sector = (c.b - c.r) / delta + 2
        } else {
            sector = (c.r - c.g) / delta + 4
        }
        return sector / 6
    }

    /// The pixel as the exact `NSColor` `colorAt` returns — for the rare probe
    /// that hands a colour back to its caller, read once, not per pixel.
    func color(_ x: Int, _ y: Int) -> NSColor? {
        bitmap.colorAt(x: x, y: y)
    }

    /// `region` (in points) converted to clamped pixel ranges at `scale`, or
    /// `nil` when it covers no pixels. The same rounding every probe used.
    func pixelRange(of region: CGRect, scale: CGFloat) -> (Range<Int>, Range<Int>)? {
        let minX = max(Int((region.minX * scale).rounded(.down)), 0)
        let maxX = min(Int((region.maxX * scale).rounded(.up)), width)
        let minY = max(Int((region.minY * scale).rounded(.down)), 0)
        let maxY = min(Int((region.maxY * scale).rounded(.up)), height)
        guard minX < maxX, minY < maxY else { return nil }
        return (minX..<maxX, minY..<maxY)
    }
}

/// Offscreen, `glassSurface()` falls back to `.regularMaterial` painted as a
/// flat, fully-opaque grey — confirmed empirically at this value in this
/// harness (see `regionHasSaturatedColor`'s doc comment, which found the same
/// constant from the saturation angle). Stable across every panel, so it
/// works as a fixed comparison colour rather than one re-sampled per render.
let glassPanelMaterialFallback = NSColor(calibratedRed: 35.0 / 255, green: 35.0 / 255, blue: 35.0 / 255, alpha: 1)

/// True when two renders differ anywhere inside `region`.
///
/// The probe for "did this parameter change anything at all". Position-based
/// probes cannot answer that for a chart whose scale adapts to its own data:
/// two very different decompositions can land at nearly the same relative
/// height, so the honest comparison is against the other render rather than
/// against a coordinate.
///
/// Compares all four components, including alpha, rather than RGB alone.
/// `renderPNG` writes unpremultiplied colour, so a pixel with alpha faded to
/// near-zero still stores full-strength RGB underneath — comparing RGB only
/// would call two renders identical when the sole difference between them is
/// exactly that faded alpha, which is precisely the kind of change (a band
/// present vs. absent at a given height) this probe exists to catch.
///
/// Requires both renders to share a scale: comparing a 1x bitmap against a 2x
/// one by pixel index would walk the two bitmaps out of registration and
/// report every pixel as differing, regardless of what either image actually
/// shows.
@MainActor
func renderedImagesDiffer(_ a: RenderedImage, _ b: RenderedImage, in region: CGRect) throws -> Bool {
    guard abs(a.scale - b.scale) < 0.001 else {
        struct ScaleMismatch: Error, CustomStringConvertible {
            let a: CGFloat
            let b: CGFloat
            var description: String { "renderedImagesDiffer requires matching scales, got \(a) and \(b)" }
        }
        throw ScaleMismatch(a: a.scale, b: b.scale)
    }

    let gridA = try PixelGrid(a)
    let gridB = try PixelGrid(b)

    let minX = max(Int((region.minX * a.scale).rounded(.down)), 0)
    let maxX = min(Int((region.maxX * a.scale).rounded(.up)), min(gridA.width, gridB.width))
    let minY = max(Int((region.minY * a.scale).rounded(.down)), 0)
    let maxY = min(Int((region.maxY * a.scale).rounded(.up)), min(gridA.height, gridB.height))
    guard minX < maxX, minY < maxY else { return false }

    // Byte comparison: these are 8-bit components decoded from a PNG, so two
    // pixels differ in a component exactly when its bytes differ — the same
    // answer the earlier half-a-step tolerance on `byte / 255` gave, with no
    // float comparison at all.
    for x in minX..<maxX {
        for y in minY..<maxY {
            if gridA.pixel(x, y) != gridB.pixel(x, y) { return true }
        }
    }
    return false
}

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
///
/// `background` is compared as bytes, so it must be an exact 8-bit colour in
/// the calibrated (Generic) RGB space `colorAt` reports in — as
/// `glassPanelMaterialFallback` is. Anything else throws rather than silently
/// matching nothing.
@MainActor
func regionHasContent(in image: RenderedImage, region: CGRect, differingFrom background: NSColor) throws -> Bool {
    let grid = try PixelGrid(image)
    let target = try PixelGrid.Pixel(exactly: background)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return false }

    for x in xs {
        for y in ys {
            if grid.pixel(x, y) != target { return true }
        }
    }
    return false
}

extension PixelGrid.Pixel {
    /// `color` as bytes, when it is exactly representable as one — the
    /// calibrated RGB space `colorAt` reports in, every component a whole
    /// number of 255ths. Throws otherwise: rounding would quietly let a
    /// colour that no pixel can equal "match" its neighbour.
    init(exactly color: NSColor) throws {
        struct NotAnExactByteColor: Error, CustomStringConvertible {
            let color: NSColor
            var description: String { "\(color) is not an exact 8-bit calibrated-RGB colour" }
        }
        guard let rgb = color.usingColorSpace(.genericRGB) else { throw NotAnExactByteColor(color: color) }
        func byte(_ component: CGFloat) throws -> UInt8 {
            let scaled = component * 255
            let rounded = scaled.rounded()
            guard abs(scaled - rounded) < 1e-6, (0...255).contains(rounded) else {
                throw NotAnExactByteColor(color: color)
            }
            return UInt8(rounded)
        }
        self.init(
            r: try byte(rgb.redComponent), g: try byte(rgb.greenComponent),
            b: try byte(rgb.blueComponent), a: try byte(rgb.alphaComponent)
        )
    }
}

/// True when any pixel inside `region` is brighter than `threshold` (0...1).
///
/// The probe for "is there light text here", where `regionHasContent` cannot
/// help: inside a chart's own area fill, every pixel already differs from the
/// background, so difference-from-background is true whether or not anything
/// was drawn on top. Brightness discriminates, because the fill's gradient has
/// faded nearly to the background by the baseline while label text has not.
///
/// Brightness is a pixel's maximum RGB component *weighted by its own alpha*
/// — not the raw RGB triplet alone. This is not optional here: `renderPNG`'s
/// PNG stores colour unpremultiplied, so a fill pixel a hair above the
/// baseline, with alpha faded to say 0.01, still stores its full-strength
/// accent-colour RGB (measured: raw max-component brightness of 1.0 in this
/// harness's own bottom-corner probe region, from fill pixels nowhere near
/// visible) — reading the RGB triplet alone would make the near-invisible
/// fill register as brighter than the label itself. Multiplying by alpha
/// converts that back into "how bright this pixel actually looks composited
/// over the background," which is the only sense of "brightness" that can
/// tell a translucent fill from opaque-ish label text.
///
/// Built on the same bitmap loading and region clamping as `regionHasContent`
/// — the only difference is what counts as "content".
@MainActor
func regionHasPixelBrighterThan(in image: RenderedImage, region: CGRect, threshold: CGFloat) throws -> Bool {
    let grid = try PixelGrid(image)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return false }

    for x in xs {
        for y in ys {
            let c = grid.components(x, y)
            let brightness = max(c.r, max(c.g, c.b)) * c.a
            if brightness > threshold { return true }
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
/// **Probe placement matters** — see `regionHasContent`'s note on
/// unpremultiplied colour. This function reads RGB spread without weighting by
/// alpha, so a fully-faded gradient pixel still reads as saturated. It also
/// cannot distinguish a light fill from a heavy one, which is why the fill
/// weight in `MetricChart.fillOpacity` is covered by a pure test rather than a
/// render probe.
///
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
    let grid = try PixelGrid(image)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return nil }

    let threshold = PixelGrid.SpreadThreshold(minimumSpread)
    for y in ys {
        if let x = grid.firstSaturatedX(inRow: y, xs, threshold) { return grid.color(x, y) }
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
    let grid = try PixelGrid(image)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return false }

    for y in ys {
        for x in xs {
            guard grid.spread(x, y) > (16.0 / 255.0) else { continue }

            let pixelHue = grid.hue(x, y)
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
///
/// Reads raw bytes rather than `colorAt` (see `PixelGrid` for why), but not
/// through `PixelGrid`: this runs on the in-memory capture, which is
/// premultiplied, unlike the straight-alpha PNG the probes decode. "Is every
/// pixel the same" is a byte question in either format, so no component maths
/// is needed — only the pixel size and row stride.
private func isNotBlank(_ bitmap: NSBitmapImageRep) throws -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
    guard !bitmap.isPlanar, bitmap.bitsPerPixel % 8 == 0, let base = bitmap.bitmapData else {
        struct UnsupportedCapture: Error, CustomStringConvertible {
            let description: String
        }
        throw UnsupportedCapture(description:
            "isNotBlank needs an interleaved, byte-aligned capture; got \(bitmap.bitsPerPixel) bits/pixel, planar \(bitmap.isPlanar)")
    }

    let pixelSize = bitmap.bitsPerPixel / 8
    let firstPixel = UnsafeRawBufferPointer(start: base, count: pixelSize)
    for y in 0..<bitmap.pixelsHigh {
        let row = base + y * bitmap.bytesPerRow
        for x in 0..<bitmap.pixelsWide {
            let pixel = UnsafeRawBufferPointer(start: row + x * pixelSize, count: pixelSize)
            if !pixel.elementsEqual(firstPixel) { return true }
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
    let grid = try PixelGrid(image)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return nil }

    let threshold = PixelGrid.SpreadThreshold(minimumSpread)
    var top: Int?
    var bottom: Int?
    for y in ys where grid.firstSaturatedX(inRow: y, xs, threshold) != nil {
        if top == nil { top = y }
        bottom = y
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
    let grid = try PixelGrid(image)
    guard let (xs, ys) = grid.pixelRange(of: region, scale: image.scale) else { return nil }

    let threshold = PixelGrid.SpreadThreshold(minimumSpread)
    var left: Int?
    var right: Int?
    for x in xs where grid.firstSaturatedY(inColumn: x, ys, threshold) != nil {
        if left == nil { left = x }
        right = x
    }

    guard let left, let right else { return nil }
    return (CGFloat(left) / image.scale)...(CGFloat(right) / image.scale)
}
