import SwiftUI
import SystemMetrics

public struct CPUPage: View {
    private let store: MetricsStore
    // `@SceneStorage`, not `@State`: `AppShell` rebuilds this page on every
    // sidebar switch, which would reset a plain `@State` to `false` each
    // time. The spec requires the disclosure to stay open once expanded, so
    // its state must survive the view being torn down and reconstructed.
    @SceneStorage("CPUPage.showFullSpecifications") private var showFullSpecifications = false

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// An absent cache level reads as unavailable. `hw.l3cachesize` genuinely
    /// does not exist on Apple Silicon, and "0 bytes" would be a lie.
    ///
    /// Returns `nil` rather than the literal string "Unavailable" so `StatRow`
    /// — not this helper — decides how absence is worded and styled. See
    /// `StatRow.displayValue` for the house rule.
    public static func formatCache(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// One stacked series per performance cluster, or a single total series on
    /// hardware that has no clusters to decompose.
    ///
    /// `CPULoadSample.clusterLoads(for:)` can legitimately omit a cluster from
    /// its dictionary when the topology's logical core count runs past the
    /// sample's actual core array (a mismatch between sysctl-derived topology
    /// and the sampled cores). A cluster missing a reading is dropped from the
    /// chart entirely rather than filled with zero — a flat 0% line would be a
    /// measurement the machine never reported.
    public static func clusterSeries(
        history: [CPULoadSample],
        topology: CPUTopology
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        guard !topology.clusters.isEmpty else {
            return [ChartSeries(name: "CPU", values: history.map(\.total))]
        }
        // Computed once per sample rather than once per cluster per sample —
        // `clusterLoads(for:)` walks every core, so calling it inside the
        // `map` below (as before) made this O(history × clusters²).
        let loadsPerSample = history.map { $0.clusterLoads(for: topology.clusters) }
        return topology.clusters.compactMap { cluster in
            let values = loadsPerSample.compactMap { $0[cluster.name] }
            guard values.count == history.count else { return nil }
            return ChartSeries(name: cluster.name, values: values)
        }
    }

    // MARK: View

    public var body: some View {
        // A plain `Spacer()` inside a bare `ScrollView` does nothing — the
        // scroll view proposes unbounded height to its content, so a trailing
        // spacer collapses to zero. `GeometryReader` supplies the visible
        // height so the content `VStack` can be told to fill at least that
        // much, which is what lets the spacer push against something on a
        // tall window instead of leaving blank scroll-view background below
        // the last panel. Content taller than the window still scrolls
        // normally.
        GeometryReader { proxy in
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
                    Spacer(minLength: 0)
                }
                .frame(minHeight: proxy.size.height, alignment: .top)
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
            StatRow(label: "Speed", value: Self.gatedValue(store.profile?.frequencyAvailable))
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
                StatRow(label: "Die temperature", value: Self.gatedValue(store.profile?.sensorsAvailable))
                StatRow(label: "Package power", value: Self.gatedValue(store.profile?.sensorsAvailable))
                StatRow(label: "Cluster frequency", value: Self.gatedValue(store.profile?.frequencyAvailable))
            }
            .padding(.top, 6)
        } label: {
            Text("Full specifications").font(Vitals.Typography.label)
        }
    }

    /// What a `StatRow` should show for a metric gated behind a hardware
    /// capability.
    ///
    /// Structurally distinct from a bare `String?` on purpose: collapsing
    /// "the capability doesn't work here," "it works but nothing has been
    /// read yet," and "here is a reading" into the same optional (as the
    /// previous `unavailableReason` helper did, always returning `nil` for
    /// `.available`) meant a capability that becomes available could only
    /// ever render as permanently "Unavailable" — silently, since nothing
    /// would fail to compile. Once frequency or sensor readings are wired up,
    /// the call site must pass a `measured` value, and `.pending` is a
    /// distinct state from `.unavailable` so the two are never conflated
    /// again even though they currently render the same way.
    private enum GatedValue {
        case measured(String)
        case unavailable(reason: String)
        case pending

        /// `StatRow`'s contract: `nil` renders as the word "Unavailable" in a
        /// de-emphasised style. Only a genuine reading is passed through as
        /// real content.
        var statRowValue: String? {
            if case .measured(let value) = self { return value }
            return nil
        }
    }

    /// Resolves what a capability-gated `StatRow` should display. `measured`
    /// is only consulted when `availability` is `.available` — an absent or
    /// unavailable capability never shows a reading regardless of what is
    /// passed.
    ///
    /// Internal rather than private so `CPUPageTests` can exercise it
    /// directly: the case this exists to prevent (`.available` silently
    /// rendering as unavailable) has no other hook to test today, since no
    /// capability on this page is actually `.available` yet.
    static func gatedValue(_ availability: MetricAvailability?, measured: String? = nil) -> String? {
        let gated: GatedValue
        switch availability {
        case nil:
            gated = .pending
        case .unavailable(let reason):
            gated = .unavailable(reason: reason)
        case .available:
            gated = measured.map(GatedValue.measured) ?? .pending
        }
        return gated.statRowValue
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}
