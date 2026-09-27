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
        MetricTile.displayValue(sample.flatMap { OverviewTiles.percent($0.total) })
    }

    /// Used over total, as a percentage — the Memory tile's bar fraction, where
    /// the tile's headline is gigabytes. No total, or a zero one, is no whole
    /// to be a fraction of: an em dash, never a guess.
    public static func memory(_ sample: MemorySample?, totalBytes: UInt64?) -> String {
        let fraction = OverviewPage.memoryFraction(usedBytes: sample?.used, totalBytes: totalBytes)
        return MetricTile.displayValue(fraction.flatMap(OverviewTiles.percent))
    }
}
