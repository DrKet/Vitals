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
    }

    public enum Metrics {
        /// Matches Apple's widget corner radius so a Vitals surface sits
        /// naturally beside a first-party one.
        public static let cornerRadius: CGFloat = 16
        public static let tileSpacing: CGFloat = 12
        public static let contentPadding: CGFloat = 20
        public static let chartHeight: CGFloat = 132
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
}
