import SwiftUI
import SystemMetrics

public struct CPUPage: View {
    private let store: MetricsStore
    @State private var showFullSpecifications = false

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// An absent cache level reads as unavailable. `hw.l3cachesize` genuinely
    /// does not exist on Apple Silicon, and "0 bytes" would be a lie.
    public static func formatCache(_ bytes: Int?) -> String {
        guard let bytes else { return "Unavailable" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// One stacked series per performance cluster, or a single total series on
    /// hardware that has no clusters to decompose.
    public static func clusterSeries(
        history: [CPULoadSample],
        topology: CPUTopology
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        guard !topology.clusters.isEmpty else {
            return [ChartSeries(name: "CPU", values: history.map(\.total))]
        }
        return topology.clusters.map { cluster in
            ChartSeries(
                name: cluster.name,
                values: history.map { $0.clusterLoads(for: topology.clusters)[cluster.name] ?? 0 }
            )
        }
    }

    // MARK: View

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
                header
                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        primaryValue
                        chart
                        coreGrid
                    }
                }
                GlassPanel { keyStatistics }
                GlassPanel { fullSpecifications }
            }
        }
        .task { await store.stream(.cpu) }
    }

    private var topology: CPUTopology? { store.profile?.cpu }

    private var header: some View {
        HStack {
            Text("CPU").font(Vitals.Typography.sectionTitle)
            Spacer()
            if let topology {
                HStack(spacing: 6) {
                    // The Apple mark is a glyph in the system font, so no asset
                    // is bundled for it.
                    if topology.isAppleSilicon { Text("\u{F8FF}") }
                    Text(topology.brand)
                }
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassSurface(cornerRadius: 20)
            }
        }
    }

    private var primaryValue: some View {
        Text(store.cpu.map { "\(Int(($0.total * 100).rounded()))%" } ?? "—")
            .font(Vitals.Typography.readout)
            .foregroundStyle(store.cpu == nil ? .secondary : .primary)
    }

    @ViewBuilder
    private var chart: some View {
        if let topology {
            let series = Self.clusterSeries(history: store.cpuHistory, topology: topology)
            MetricChart(
                series: series,
                style: .area(stacked: series.count > 1),
                colors: Vitals.seriesColors(count: max(series.count, 1))
            )
        }
    }

    @ViewBuilder
    private var coreGrid: some View {
        if let cores = store.cpu?.cores, !cores.isEmpty {
            CoreGrid(cores: cores, accent: Vitals.Palette.cpu)
            if let clusters = topology?.clusters, !clusters.isEmpty {
                HStack {
                    ForEach(clusters, id: \.name) { cluster in
                        Text("\(cluster.coreCount) \(cluster.name)")
                            .font(Vitals.Typography.label)
                            .foregroundStyle(.secondary)
                        if cluster.name != clusters.last?.name { Spacer() }
                    }
                }
            }
        }
    }

    /// The four numbers you actually watch. Everything else lives behind the
    /// disclosure below.
    private var keyStatistics: some View {
        let load = store.systemLoad
        return VStack(spacing: 0) {
            StatRow(label: "Cores", value: coreCountDescription)
            StatRow(label: "Load average", value: load.loadAverage1.map { String(format: "%.2f", $0) })
            StatRow(label: "Uptime", value: Self.formatUptime(load.uptimeSeconds))
            StatRow(label: "Speed", value: unavailableReason(store.profile?.frequencyAvailable))
        }
    }

    /// Both counts are `Int?` — an absent sysctl reads nil, never 0 — so this
    /// describes whichever parts are actually known.
    private var coreCountDescription: String? {
        guard let topology else { return nil }
        switch (topology.physicalCores, topology.logicalCores) {
        case let (physical?, logical?): return "\(physical) physical, \(logical) logical"
        case let (physical?, nil): return "\(physical) physical"
        case let (nil, logical?): return "\(logical) logical"
        case (nil, nil): return nil
        }
    }

    private var fullSpecifications: some View {
        DisclosureGroup(isExpanded: $showFullSpecifications) {
            VStack(spacing: 0) {
                StatRow(label: "Architecture", value: topology?.isAppleSilicon == true ? "arm64e" : "x86_64")
                StatRow(label: "L1 data cache", value: Self.formatCache(topology?.l1DataCacheBytes))
                StatRow(label: "L2 cache", value: Self.formatCache(topology?.l2CacheBytes))
                StatRow(label: "L3 cache", value: Self.formatCache(topology?.l3CacheBytes))
                StatRow(label: "Load average (5m)", value: store.systemLoad.loadAverage5.map { String(format: "%.2f", $0) })
                StatRow(label: "Load average (15m)", value: store.systemLoad.loadAverage15.map { String(format: "%.2f", $0) })
                StatRow(label: "Die temperature", value: unavailableReason(store.profile?.sensorsAvailable))
                StatRow(label: "Package power", value: unavailableReason(store.profile?.sensorsAvailable))
                StatRow(label: "Cluster frequency", value: unavailableReason(store.profile?.frequencyAvailable))
            }
            .padding(.top, 6)
        } label: {
            Text("Full specifications").font(Vitals.Typography.label)
        }
    }

    /// Renders a capability's unavailability, so the page explains itself rather
    /// than showing a blank row.
    private func unavailableReason(_ availability: MetricAvailability?) -> String? {
        guard let availability else { return nil }
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}
