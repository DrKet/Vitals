import SwiftUI
import SystemMetrics

/// Live tile grid. Tiles reflow and grow into available height as the window
/// resizes — the spec is explicit that leftover vertical space belongs to the
/// data, not to emptiness.
public struct OverviewPage: View {
    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    private var tiles: [OverviewTile] {
        OverviewTiles.tiles(ids: Self.tileOrder(hasBattery: store.profile?.hasBattery == true), store: store)
    }

    public var body: some View {
        // `TileGrid` rather than `LazyVGrid`: a lazy grid sizes its rows to
        // their content, which strands two tiles at the top of a tall window.
        TileGrid(
            items: tiles,
            // ~340pt gives two columns in a typical window and three at
            // fullscreen, measured against the real detail area — the sidebar
            // takes ~250pt, so the grid is far narrower than the window, and a
            // larger minimum collapses to a single tall column. The cap of
            // three keeps an ultrawide display from stranding a lopsided
            // five-plus-one row. Together they guarantee at least two rows, so
            // no tile can fill the whole window height.
            minimumTileWidth: 340,
            maximumColumns: 3,
            maximumRowHeight: Vitals.Metrics.overviewTileMaxHeight
        ) { tile in
            MetricTile(
                label: tile.label,
                value: tile.value,
                accent: tile.accent,
                fraction: tile.fraction,
                series: tile.series
            )
        }
        .task { await store.stream(.cpu) }
        .task { await store.stream(.memory) }
        .task { await store.stream(.gpu) }
        .task { await store.stream(.diskIO) }
        .task { await store.stream(.network) }
        // Battery is sampled only where it exists — a desktop never subscribes
        // to a series it cannot show. The task runs on every machine but
        // returns immediately when there is no battery.
        .task {
            guard store.profile?.hasBattery == true else { return }
            await store.stream(.battery)
        }
    }

    // MARK: GPU

    /// Same primary as `GPUPage`, including the multi-GPU attribution gate —
    /// a reading we cannot attribute must not appear on the Overview either.
    ///
    /// Internal so `OverviewPageTests` can exercise the gate directly without
    /// rendering the full tile grid.
    static func gpuTileValue(sample: GPUSample?, gpuCount: Int, sampleCount: Int) -> String? {
        GPUPage.attributableLatest(sample, gpuCount: gpuCount, sampleCount: sampleCount)?
            .deviceUtilisation.map { "\(Int(($0 * 100).rounded()))%" }
    }

    /// The Overview GPU tile's bar value: the attributable device utilisation,
    /// or `nil`. Mirrors `gpuTileValue`'s gate exactly — the raw fraction the
    /// value formats as a percentage — so the bar is present precisely when the
    /// value is, and never attributes one GPU's load under a generic label on a
    /// multi-GPU Mac.
    static func gpuTileFraction(sample: GPUSample?, gpuCount: Int, sampleCount: Int) -> Double? {
        GPUPage.attributableLatest(sample, gpuCount: gpuCount, sampleCount: sampleCount)?.deviceUtilisation
    }

    /// Overview's GPU tile chart: whole-device utilisation, never
    /// Renderer+Tiler summed — see `GPUPage.deviceUtilisationSeries`'s doc
    /// comment for why that sum would be a fabricated quantity. Gated by the
    /// same multi-GPU attribution rule as the tile's value and as `GPUPage`'s
    /// own chart.
    ///
    /// Internal so `OverviewPageTests` can prove the tile is wired to
    /// `deviceUtilisationSeries` and not `engineSeries` — a regression a
    /// pixel probe over the tile's tiny chart could not reliably catch,
    /// since both would paint *some* line.
    static func gpuTileSeries(
        history: [Timestamped<[GPUSample]>],
        gpuCount: Int,
        sampleCount: Int
    ) -> [ChartSeries] {
        GPUPage.attributableSeries(
            GPUPage.deviceUtilisationSeries(history: history),
            gpuCount: gpuCount,
            sampleCount: sampleCount
        )
    }

    // MARK: Memory

    /// The Memory tile's bar value: used over total, or `nil` when there is no
    /// total to be a fraction of. Guards `total > 0` for the same reason the
    /// memory series does — a machine that cannot report `hw.memsize` has no
    /// whole, and dividing by it would be a fabricated proportion.
    static func memoryFraction(usedBytes: UInt64?, totalBytes: UInt64?) -> Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    // MARK: Storage

    /// Overview's Storage tile chart: the same read+write total as the
    /// tile's own headline (`StoragePage.primaryValue`), never the page's two
    /// stacked bands. Internal so `OverviewPageTests` can prove the tile
    /// routes through `totalThroughputSeries`, not `throughputSeries`.
    static func storageTileSeries(history: [Timestamped<[String: DiskThroughput]>]) -> [ChartSeries] {
        StoragePage.totalThroughputSeries(history: history)
    }

    // MARK: Network

    /// Same primary as `NetworkPage`, including the lo0-only → nil gate so a
    /// tick with no real interfaces never headlines as a measured zero.
    /// Routes through `NetworkPage.primaryValue` so the tile cannot drift
    /// from the page it mirrors.
    ///
    /// Internal so `OverviewPageTests` can exercise the gate directly.
    static func networkTileValue(_ network: [String: NetworkThroughput]?) -> String? {
        NetworkPage.primaryValue(network)
    }

    /// Overview's Network tile chart: the same down+up total as the tile's
    /// own headline (`NetworkPage.primaryValue`), never the page's two
    /// stacked bands. Internal so `OverviewPageTests` can prove the tile
    /// routes through `totalThroughputSeries`, not `throughputSeries`.
    static func networkTileSeries(history: [Timestamped<[String: NetworkThroughput]>]) -> [ChartSeries] {
        NetworkPage.totalThroughputSeries(history: history)
    }

    // MARK: Tile ordering

    /// The tiles the Overview shows, in order. Battery is appended only on a
    /// machine that has one — six tiles divide into a clean grid where five
    /// leave a gap, but a desktop Mac has no battery to show. The body builds
    /// its tiles from exactly this list, so presence lives in one tested place.
    static func tileOrder(hasBattery: Bool) -> [String] {
        ["cpu", "memory", "gpu", "storage", "network"] + (hasBattery ? ["battery"] : [])
    }
}
