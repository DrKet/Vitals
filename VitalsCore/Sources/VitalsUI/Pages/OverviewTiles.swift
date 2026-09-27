import SwiftUI
import SystemMetrics

/// One Overview tile's worth of state: what it is called, what it reads, its
/// accent, its bar fraction and its sparkline.
struct OverviewTile: Identifiable {
    let id: String
    let label: String
    let value: String?
    let accent: Color
    let fraction: Double?
    let series: [ChartSeries]
}

/// Builds Overview tiles from the store — the one place a tile's value,
/// fraction and series are decided.
///
/// Shared by the Overview grid and the menu-bar dropdown, so a reading shown
/// in the menu bar is provably the one the Overview shows, including the
/// GPU page's multi-GPU attribution gate.
@MainActor
enum OverviewTiles {

    static func tiles(ids: [String], store: MetricsStore) -> [OverviewTile] {
        ids.compactMap { tile(id: $0, store: store) }
    }

    static func tile(id: String, store: MetricsStore) -> OverviewTile? {
        switch id {
        case "cpu":
            return OverviewTile(
                id: "cpu", label: "CPU",
                value: store.cpu.flatMap { percent($0.total) },
                accent: Vitals.Palette.cpu,
                fraction: store.cpu?.total,
                series: cpuSeries(store)
            )
        case "memory":
            return OverviewTile(
                id: "memory", label: "Memory",
                value: store.memory.map { Vitals.formatKnownByteCountInGigabytes($0.used) },
                accent: Vitals.Palette.memory,
                fraction: OverviewPage.memoryFraction(
                    usedBytes: store.memory?.used,
                    totalBytes: store.profile?.memory.totalBytes
                ),
                series: memorySeries(store)
            )
        case "gpu":
            return OverviewTile(
                id: "gpu", label: "GPU",
                value: OverviewPage.gpuTileValue(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                accent: Vitals.Palette.gpu,
                fraction: OverviewPage.gpuTileFraction(
                    sample: store.gpu?.first,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                ),
                series: OverviewPage.gpuTileSeries(
                    history: store.gpuHistory,
                    gpuCount: store.profile?.gpus.count ?? 0,
                    sampleCount: store.gpu?.count ?? 0
                )
            )
        case "storage":
            return OverviewTile(
                id: "storage", label: "Storage",
                value: StoragePage.primaryValue(store.diskIO),
                accent: Vitals.Palette.storage,
                fraction: nil,
                series: OverviewPage.storageTileSeries(history: store.diskIOHistory)
            )
        case "network":
            return OverviewTile(
                id: "network", label: "Network",
                value: OverviewPage.networkTileValue(store.network),
                accent: Vitals.Palette.network,
                fraction: nil,
                series: OverviewPage.networkTileSeries(history: store.networkHistory)
            )
        case "battery":
            return OverviewTile(
                id: "battery", label: "Battery",
                value: store.battery.map { "\($0.chargePercent)%" },
                accent: Vitals.Palette.battery,
                fraction: store.battery.map { Double($0.chargePercent) / 100 },
                series: batterySeries(store)
            )
        default:
            return nil
        }
    }

    /// A fraction as a whole percentage — "23%". `nil` for a non-finite
    /// fraction: `Int(_:)` on NaN or infinity traps, and neither is a
    /// measurement.
    static func percent(_ fraction: Double) -> String? {
        guard let whole = Int(exactly: (fraction * 100).rounded()) else { return nil }
        return "\(whole)%"
    }

    private static func cpuSeries(_ store: MetricsStore) -> [ChartSeries] {
        [
            ChartSeries(
                name: "CPU",
                values: store.cpuHistory.map(\.sample.total),
                timestamps: store.cpuHistory.map(\.timestamp)
            )
        ]
    }

    private static func memorySeries(_ store: MetricsStore) -> [ChartSeries] {
        guard let total = store.profile?.memory.totalBytes, total > 0 else { return [] }
        return [
            ChartSeries(
                name: "Used",
                values: store.memoryHistory.map { Double($0.sample.used) / Double(total) },
                timestamps: store.memoryHistory.map(\.timestamp)
            )
        ]
    }

    /// The Battery tile's spark: charge over time as a fraction, matching the
    /// tile's own percentage headline and its bar.
    private static func batterySeries(_ store: MetricsStore) -> [ChartSeries] {
        [
            ChartSeries(
                name: "Charge",
                values: store.batteryHistory.map { Double($0.sample.chargePercent) / 100 },
                timestamps: store.batteryHistory.map(\.timestamp)
            )
        ]
    }
}
