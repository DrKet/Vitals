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

    /// A stable colour per series index, for stacked charts.
    ///
    /// Ordering is fixed so a chart's colours do not shuffle between renders.
    /// The ramp wraps rather than truncating, so a caller asking for more series
    /// than there are hues still gets one colour per series.
    public static func seriesColors(count: Int) -> [Color] {
        guard count > 0 else { return [] }
        let ramp: [Color] = [
            Palette.cpu,
            Palette.storage,
            Palette.memory,
            Palette.gpu,
            Palette.network,
            Palette.warning,
        ]
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
