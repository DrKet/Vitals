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

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: Vitals.Metrics.tileSpacing)
    ]

    public var body: some View {
        LazyVGrid(columns: columns, spacing: Vitals.Metrics.tileSpacing) {
            MetricTile(
                label: "CPU",
                value: store.cpu.map { "\(Int(($0.total * 100).rounded()))%" },
                accent: Vitals.Palette.cpu,
                series: cpuSeries
            )
            MetricTile(
                label: "Memory",
                value: store.memory.map { formatBytes($0.used) },
                accent: Vitals.Palette.memory,
                series: memorySeries
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await store.stream(.cpu) }
        .task { await store.stream(.memory) }
    }

    private var cpuSeries: [ChartSeries] {
        [ChartSeries(name: "CPU", values: store.cpuHistory.map(\.total))]
    }

    private var memorySeries: [ChartSeries] {
        guard let total = store.profile?.memory.totalBytes, total > 0 else { return [] }
        return [
            ChartSeries(
                name: "Used",
                values: store.memoryHistory.map { Double($0.used) / Double(total) }
            )
        ]
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
