import SwiftUI
import SystemMetrics

public struct MemoryPage: View {
    /// Exposed so `PageConsistencyTests` can verify no two pages share a key —
    /// a shared key would make one page's disclosure expand every other's.
    public static let disclosureKey = "MemoryPage.showFullSpecifications"

    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// The four bands from spec §6.3, as fractions of installed memory.
    ///
    /// Base first: Wired is the floor the kernel will not give back, App sits
    /// on it, then Compressed, then Cached.
    public static func breakdownSeries(
        history: [Timestamped<MemorySample>],
        installedBytes: UInt64
    ) -> [ChartSeries] {
        guard !history.isEmpty, installedBytes > 0 else { return [] }

        let total = Double(installedBytes)
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (MemorySample) -> UInt64) -> ChartSeries {
            ChartSeries(
                name: name,
                values: history.map { Double(value($0.sample)) / total },
                timestamps: timestamps
            )
        }

        return [
            band("Wired") { $0.wired },
            band("App") { $0.app },
            band("Compressed") { $0.compressed },
            band("Cached") { $0.cached },
        ]
    }

    // MARK: View

    private var hardware: MemoryHardware? { store.profile?.memory }

    public var body: some View {
        HardwarePage(
            title: "Memory",
            vendorName: hardware.flatMap { Vitals.formatByteCount($0.totalBytes) },
            showsAppleMark: hardware?.isUnified == true,
            primaryValue: store.memory.flatMap { Vitals.formatByteCount($0.used) },
            series: hardware.map {
                Self.breakdownSeries(history: store.memoryHistory, installedBytes: $0.totalBytes)
            } ?? [],
            accent: Vitals.Palette.memory,
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            EmptyView()
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.memory) }
    }

    private var stats: [HardwareStat] {
        [
            HardwareStat(label: "Installed", value: Vitals.formatByteCount(hardware?.totalBytes)),
            HardwareStat(label: "Cached files", value: Vitals.formatByteCount(store.memory?.cached)),
            HardwareStat(label: "Swap used", value: Vitals.formatByteCount(store.memory?.swapUsed)),
            HardwareStat(label: "Pressure", value: store.memory?.pressure.map(Self.describe)),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        StatRow(label: "Type", value: hardware?.type)
        StatRow(label: "Manufacturer", value: hardware?.manufacturer)
        StatRow(label: "Unified", value: hardware.map { $0.isUnified ? "Yes" : "No" })
        // Apple Silicon exposes no memory clock. Showing the SoC's published
        // bandwidth — explicitly labelled a specification — is honest; a
        // fabricated MHz figure would not be. Intel Macs report real per-DIMM
        // speeds, and get the speed row instead.
        StatRow(label: "Speed", value: hardware?.speedMHz.map { "\($0) MHz" })
        StatRow(
            label: "Peak bandwidth",
            value: hardware?.peakBandwidthGBs.map { "\($0) GB/s (specification)" }
        )
        StatRow(label: "Wired", value: Vitals.formatByteCount(store.memory?.wired))
        StatRow(label: "Compressed", value: Vitals.formatByteCount(store.memory?.compressed))
        ForEach(hardware?.slots ?? [], id: \.name) { slot in
            StatRow(
                label: slot.name,
                value: [slot.sizeDescription, slot.type, slot.speedMHz.map { "\($0) MHz" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
        }
    }

    private static func describe(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}
