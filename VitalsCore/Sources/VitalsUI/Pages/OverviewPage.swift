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

    /// One tile's worth of state, so the grid can lay them out generically.
    private struct Tile: Identifiable {
        let id: String
        let label: String
        let value: String?
        let accent: Color
        let series: [ChartSeries]
    }

    private var tiles: [Tile] {
        [
            Tile(
                id: "cpu",
                label: "CPU",
                value: store.cpu.map { "\(Int(($0.total * 100).rounded()))%" },
                accent: Vitals.Palette.cpu,
                series: cpuSeries
            ),
            Tile(
                id: "memory",
                label: "Memory",
                value: store.memory.map { Vitals.formatKnownByteCountInGigabytes($0.used) },
                accent: Vitals.Palette.memory,
                series: memorySeries
            ),
            Tile(
                id: "gpu",
                label: "GPU",
                value: Self.gpuTileValue(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                accent: Vitals.Palette.gpu,
                series: gpuSeries
            ),
            Tile(
                id: "storage",
                label: "Storage",
                value: StoragePage.primaryValue(store.diskIO),
                accent: Vitals.Palette.storage,
                series: storageSeries
            ),
            Tile(
                id: "network",
                label: "Network",
                value: Self.networkTileValue(store.network),
                accent: Vitals.Palette.network,
                series: networkSeries
            ),
        ]
    }

    public var body: some View {
        // `TileGrid` rather than `LazyVGrid`: a lazy grid sizes its rows to
        // their content, which strands two tiles at the top of a tall window.
        TileGrid(items: tiles) { tile in
            MetricTile(
                label: tile.label,
                value: tile.value,
                accent: tile.accent,
                series: tile.series
            )
        }
        .task { await store.stream(.cpu) }
        .task { await store.stream(.memory) }
        .task { await store.stream(.gpu) }
        .task { await store.stream(.diskIO) }
        .task { await store.stream(.network) }
    }

    private var cpuSeries: [ChartSeries] {
        [
            ChartSeries(
                name: "CPU",
                values: store.cpuHistory.map(\.sample.total),
                timestamps: store.cpuHistory.map(\.timestamp)
            )
        ]
    }

    private var memorySeries: [ChartSeries] {
        guard let total = store.profile?.memory.totalBytes, total > 0 else { return [] }
        return [
            ChartSeries(
                name: "Used",
                values: store.memoryHistory.map { Double($0.sample.used) / Double(total) },
                timestamps: store.memoryHistory.map(\.timestamp)
            )
        ]
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

    private var gpuSeries: [ChartSeries] {
        Self.gpuTileSeries(
            history: store.gpuHistory,
            gpuCount: store.profile?.gpus.count ?? 0,
            sampleCount: store.gpu?.count ?? 0
        )
    }

    // MARK: Storage

    /// Overview's Storage tile chart: the same read+write total as the
    /// tile's own headline (`StoragePage.primaryValue`), never the page's two
    /// stacked bands. Internal so `OverviewPageTests` can prove the tile
    /// routes through `totalThroughputSeries`, not `throughputSeries`.
    static func storageTileSeries(history: [Timestamped<[String: DiskThroughput]>]) -> [ChartSeries] {
        StoragePage.totalThroughputSeries(history: history)
    }

    private var storageSeries: [ChartSeries] {
        Self.storageTileSeries(history: store.diskIOHistory)
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

    private var networkSeries: [ChartSeries] {
        Self.networkTileSeries(history: store.networkHistory)
    }
}
