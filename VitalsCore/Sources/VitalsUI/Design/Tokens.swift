import SwiftUI

/// Design tokens. One edit here restyles the whole app, which is the point of
/// keeping them out of the views.
public enum Vitals {

    /// Per-subsystem accent colours. Each hardware page owns one hue so a glance
    /// at a chart identifies its subject without reading the label.
    public enum Palette {
        public static let cpu = Color(red: 0.49, green: 0.78, blue: 1.00)
        public static let memory = Color(red: 0.70, green: 0.61, blue: 1.00)
        public static let gpu = Color(red: 1.00, green: 0.70, blue: 0.49)
        public static let storage = Color(red: 0.56, green: 0.88, blue: 0.75)
        public static let network = Color(red: 0.98, green: 0.80, blue: 0.45)
        public static let warning = Color(red: 1.00, green: 0.47, blue: 0.47)

        /// The Sensors page's hue. Pink/magenta, chosen to be distinct from
        /// every other page accent AND from `warning` red — that red is kept
        /// out of the series ramp so it always means "something is wrong",
        /// which matters more on a thermal page than anywhere else.
        public static let sensors = Color(red: 0.98, green: 0.55, blue: 0.78)

        /// A sixth ramp hue that identifies no subsystem — it exists solely
        /// to keep Memory's four-band stack (Wired / App / Compressed /
        /// Cached) legible. Without it, `seriesRamp`'s `gpu` (~24.7°) and
        /// `network` (~39.6°) land adjacent in that rotation only 15° apart,
        /// reading as one band. This pastel pink (~326° hue, ~0.42
        /// saturation, full brightness) is far enough from both `gpu` and
        /// `network` (>36° either way) to separate them.
        /// Do not repurpose this for an actual subsystem or delete it as
        /// "unused" — nothing reads it directly, but removing it reopens the
        /// 15° collision `TokensTests.memoryFourBandsStayDistinctWithoutWarning`
        /// guards against.
        ///
        /// It no longer sits in an otherwise-empty hue range, as this comment
        /// used to claim: `Palette.sensors` was added ~2° away. That is safe,
        /// but only because the two can never share a chart — `sensors` is
        /// absent from `seriesRamp`, so `seriesColors(startingAt:)` *prepends*
        /// it and falls back to the unrotated ramp, and the Sensors page asks
        /// for three series, stopping well before this entry at position 5.
        /// `TokensTests.sensorsAccentNeverMeetsTheLegibilityAccent` pins that,
        /// so a future page leading with `sensors` and asking for enough series
        /// to reach here fails there rather than quietly rendering two pinks a
        /// viewer cannot tell apart.
        public static let legibilityAccent = Color(red: 1.00, green: 0.58, blue: 0.82)

        /// The Battery page's hue.
        ///
        /// Green at roughly 100 degrees — the largest genuinely free gap in the
        /// ramp, about 50 degrees from `network` (43) and from `storage` (156).
        /// Green-for-battery is also a convention nobody has to learn.
        public static let battery = Color(red: 0.55, green: 0.80, blue: 0.35)
    }

    public enum Metrics {
        /// Matches Apple's widget corner radius so a Vitals surface sits
        /// naturally beside a first-party one.
        public static let cornerRadius: CGFloat = 16
        public static let tileSpacing: CGFloat = 12
        public static let contentPadding: CGFloat = 20
        public static let chartHeight: CGFloat = 132
        /// The ceiling `HardwarePage` holds its chart to.
        ///
        /// `HardwarePage` pins its content stack to the window height so a
        /// trailing spacer has something to push against, and `MetricChart`
        /// declares `maxHeight: .infinity` so a tall tile shows more history.
        /// Together those made the chart the only greedy element on the page:
        /// on the four pages whose `secondary` slot is empty it took ~49% of a
        /// 713pt window and grew from there. The floor above is a guarantee;
        /// this is a limit. Deliberately not a fraction of window height —
        /// that would mean threading the container's geometry into the chart,
        /// widening `MetricChart`'s API for a layout concern that belongs to
        /// its caller.
        public static let chartMaxHeight: CGFloat = 220

        /// The tallest an Overview tile row grows to before the grid stops
        /// filling and leaves space below.
        ///
        /// The Overview grid divides height equally across its rows, so on an
        /// ordinary fullscreen window the tiles fill it — the state the layout
        /// was designed in. This ceiling engages only on an unusually tall
        /// window (a portrait display, a tall resize), where unbounded growth
        /// would recreate the very tallness this layout exists to cure, one row
        /// later. Mirrors `chartMaxHeight`: a layout limit owned by the
        /// container, not the leaf.
        ///
        /// Measured, not guessed: a fullscreen 1512×982 window gives the grid
        /// roughly 950pt of height, so its two rows want about 470pt each. The
        /// ceiling sits above that so an ordinary fullscreen fills edge to edge
        /// — the state the layout was approved in — and only engages once a
        /// row would exceed ~520pt, i.e. a window taller than ~1050pt of grid
        /// (a portrait display). A lower value (an earlier draft used 340)
        /// caps the tiles short of an ordinary fullscreen and pools an empty
        /// band below, which is the exact look this rework exists to remove.
        public static let overviewTileMaxHeight: CGFloat = 520
    }

    public enum Chart {
        /// The load-reactive bloom drawn behind a chart's stroke.
        ///
        /// A blurred, additively-blended copy of the line sits *behind* the
        /// crisp 2pt stroke — so the reading stays sharp — with its weight tied
        /// to how high the line sits on the scale: an idle trace hugging the
        /// baseline stays flat, and the busy stretches bloom on their own. The
        /// glow is purely decorative: every value the reader takes off the
        /// chart comes from the crisp stroke and the fill, never from the
        /// halo, so it is always safe to dial to zero.
        ///
        /// A struct rather than the loose statics `Metrics` uses, so a test can
        /// build a variant (a disabled config, an exaggerated one) and pin the
        /// ramp — see `MetricChart.glowLevel(atHeight:config:)`, tested the same
        /// way `fillOpacity` is, because render probes cannot read the glow's
        /// weight off an unpremultiplied PNG.
        public struct Glow: Sendable {
            /// Master switch. `false` restores the exact pre-glow render — no
            /// extra layer is drawn at all, not merely one at zero opacity.
            public let isEnabled: Bool
            /// Blur radius (pt) the glow reaches at the top of the scale. The
            /// idle end of the ramp collapses toward the stroke's own width, so
            /// a low line reads as a faint sheen rather than a halo.
            public let maxRadius: CGFloat
            /// The extra opacity the glow's stroke carries at the top of the
            /// scale, added over the opaque crisp stroke beneath it.
            public let maxOpacity: Double
            /// Normalised height (0…1) below which no glow draws at all, so the
            /// idle baseline is genuinely flat and not faintly lit. Mirrors the
            /// glow study's idle floor.
            public let floor: Double

            public init(isEnabled: Bool, maxRadius: CGFloat, maxOpacity: Double, floor: Double) {
                self.isEnabled = isEnabled
                self.maxRadius = maxRadius
                self.maxOpacity = maxOpacity
                self.floor = floor
            }
        }

        /// The house pick from the glow study: the "strong" bloom, reactive to
        /// load. One edit here restyles every chart in the app.
        public static let glow = Glow(isEnabled: true, maxRadius: 12, maxOpacity: 0.60, floor: 0.12)
    }

    public enum Typography {
        /// Large numeric readouts. Monospaced digits so a changing value does not
        /// jitter its own layout — the single most important typographic choice
        /// in a live monitor.
        public static let readout = Font.system(size: 40, weight: .semibold, design: .rounded)
            .monospacedDigit()
        public static let tileValue = Font.system(size: 22, weight: .semibold)
            .monospacedDigit()
        public static let label = Font.system(size: 11, weight: .medium)
        public static let sectionTitle = Font.system(size: 13, weight: .semibold)
    }

    /// The fixed ramp `seriesColors` draws from, in order. Shared by both
    /// overloads below so there is exactly one place that lists the hues.
    ///
    /// `Palette.warning` is deliberately excluded. It rotated into two data
    /// bands (Memory's *Cached files*, Network's *Up*) once charts started
    /// leading with each page's own accent, and red on a band that is not
    /// reporting a problem reads as a false alarm. Nothing reads `.warning`
    /// as a live semantic colour today, so keeping it out of the ramp costs
    /// nothing and reserves it for an actual warning later.
    private static let seriesRamp: [Color] = [
        Palette.cpu,
        Palette.storage,
        Palette.memory,
        Palette.gpu,
        Palette.legibilityAccent,
        Palette.network,
    ]

    /// A stable colour per series index, for stacked charts.
    ///
    /// Ordering is fixed so a chart's colours do not shuffle between renders.
    /// The ramp wraps rather than truncating, so a caller asking for more series
    /// than there are hues still gets one colour per series.
    ///
    /// Always starts at `Palette.cpu` — a thin wrapper over
    /// `seriesColors(startingAt:count:)` below, for callers with no
    /// particular hue to lead with.
    public static func seriesColors(count: Int) -> [Color] {
        seriesColors(startingAt: Palette.cpu, count: count)
    }

    /// Like `seriesColors(count:)`, but rotated so `accent` leads the ramp
    /// instead of always starting at `Palette.cpu`.
    ///
    /// This is what lets a hardware page's chart open on the same hue as its
    /// Overview tile — see the doc comment atop this file. When `accent` is
    /// one of the hues already in the base ramp (true of every call site
    /// today, which all pass a `Vitals.Palette` colour), the ramp is rotated
    /// rather than having `accent` prepended, so every hue still appears
    /// exactly once — prepending would duplicate it at both its original
    /// position and position 0, which would make two bands on the same chart
    /// indistinguishable. An `accent` the base ramp does not recognise is
    /// simply prepended instead, since there is nothing to deduplicate
    /// against.
    public static func seriesColors(startingAt accent: Color, count: Int) -> [Color] {
        guard count > 0 else { return [] }
        if let startIndex = seriesRamp.firstIndex(of: accent) {
            let rotated = Array(seriesRamp[startIndex...] + seriesRamp[..<startIndex])
            return (0..<count).map { rotated[$0 % rotated.count] }
        }
        let ramp = [accent] + seriesRamp
        return (0..<count).map { ramp[$0 % ramp.count] }
    }

    /// Formats a byte count in the memory-oriented style (KB/MB/GB, base
    /// 1024) used across hardware pages for installed memory, cache sizes,
    /// and similar readings.
    ///
    /// Returns `nil` for an absent reading rather than a baked-in placeholder
    /// string, so the caller — `StatRow` or `MetricTile` — is the single
    /// place that decides how absence is worded and styled.
    public static func formatByteCount<T: BinaryInteger>(_ bytes: T?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Formats a byte count that can never be absent — a volume's used/total
    /// bytes, a GPU memory topology's size — where the value is a plain,
    /// non-optional `BinaryInteger` rather than a reading that might not have
    /// been taken.
    ///
    /// Feeding a non-optional input into `formatByteCount(_:)` above can
    /// never produce `nil`, since it only returns `nil` to propagate an
    /// absent *optional* reading. That makes the force-unwrap here safe by
    /// construction, not by assumption — callers should reach for this
    /// instead of re-deriving the same unwrap at each call site.
    public static func formatKnownByteCount<T: BinaryInteger>(_ bytes: T) -> String {
        formatByteCount(bytes)!
    }

    /// Like `formatKnownByteCount`, but pinned to gigabytes.
    ///
    /// Compact Overview tiles use this so the unit does not jump (MB ↔ GB)
    /// as the value crosses 1 GB and shift the readout's width. Hardware
    /// pages keep the unrestricted formatter — they have room for the unit
    /// to change.
    public static func formatKnownByteCountInGigabytes<T: BinaryInteger>(_ bytes: T) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Bytes-per-second → megabytes-per-second divisor, shared by every
    /// throughput readout and chart band so pages cannot drift onto a
    /// different definition of "MB/s".
    public static let bytesPerMegabyte = 1_048_576.0

    /// Converts a byte-per-second rate into megabytes per second.
    public static func megabytesPerSecond(fromBytesPerSecond bytesPerSecond: Double) -> Double {
        bytesPerSecond / bytesPerMegabyte
    }

    /// Formats a megabytes-per-second rate the way Storage and Network
    /// primaries read — two decimal places, always labelled `MB/s`.
    public static func formatMegabytesPerSecond(_ megabytesPerSecond: Double) -> String {
        String(format: "%.2f MB/s", megabytesPerSecond)
    }
}
