import SystemMetrics

/// The menu-bar readout's two strings. Built from the Overview's own pieces —
/// its percentage formatting and its memory fraction — so the menu bar cannot
/// disagree with the tiles, and worded for absence exactly as a tile is.
///
/// Main-actor isolated because those pieces are: `OverviewPage` is a SwiftUI
/// `View`, and `OverviewTiles` builds tiles from the main-actor store.
@MainActor
public enum MenuBarReadout {

    public static func cpu(_ sample: CPULoadSample?) -> String {
        pad(MetricTile.displayValue(sample.flatMap { OverviewTiles.percent($0.total) }))
    }

    /// Used over total, as a percentage — the Memory tile's bar fraction, where
    /// the tile's headline is gigabytes. No total, or a zero one, is no whole
    /// to be a fraction of: an em dash, never a guess.
    public static func memory(_ sample: MemorySample?, totalBytes: UInt64?) -> String {
        let fraction = OverviewPage.memoryFraction(usedBytes: sample?.used, totalBytes: totalBytes)
        return pad(MetricTile.displayValue(fraction.flatMap(OverviewTiles.percent)))
    }

    /// Pads a numeric reading's digits out to three with leading FIGURE
    /// SPACES (U+2007 — exactly one digit wide, unlike an ordinary space), so
    /// "9%", "23%" and "100%" all occupy the same width and the menu-bar item
    /// does not jitter as the digit count changes. `.monospacedDigit()` alone
    /// only equalises the width of one digit against another; it does
    /// nothing about there being one digit fewer.
    ///
    /// The em dash is left bare: absence is transient (the very next tick
    /// usually has a reading), so the width may change only between "—" and
    /// a number, never between two numbers.
    private static func pad(_ value: String) -> String {
        guard value.hasSuffix("%") else { return value }
        let digits = value.count - 1
        guard digits < 3 else { return value }
        return String(repeating: "\u{2007}", count: 3 - digits) + value
    }
}
