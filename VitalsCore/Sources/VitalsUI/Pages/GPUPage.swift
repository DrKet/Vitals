import SwiftUI
import SystemMetrics

public struct GPUPage: View {
    /// Exposed so `PageConsistencyTests` can verify no two pages share a key —
    /// a shared key would make one page's disclosure expand every other's.
    public static let disclosureKey = "GPUPage.showFullSpecifications"

    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// Renderer and tiler utilisation, per spec §6.3.
    ///
    /// Both fields are optional because which keys a driver publishes varies.
    /// An engine the driver never reported is omitted entirely — a flat 0%
    /// band would claim a measurement that was never taken.
    public static func engineSeries(history: [Timestamped<[GPUSample]>]) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (GPUSample) -> Double?) -> ChartSeries? {
            let values = history.compactMap { entry in entry.sample.first.flatMap(value) }
            guard values.count == history.count else { return nil }
            return ChartSeries(name: name, values: values, timestamps: timestamps)
        }

        return [
            band("Renderer") { $0.rendererUtilisation },
            band("Tiler") { $0.tilerUtilisation },
        ].compactMap { $0 }
    }

    /// The three memory topologies mean different things to a reader — one
    /// pool shared with the CPU, a card's own VRAM, or a slice carved out of
    /// system RAM — so each is worded distinctly rather than flattened into a
    /// byte count.
    public static func describeMemory(_ topology: GPUMemoryTopology) -> String {
        switch topology {
        case .unified(let bytes):
            return "\(Vitals.formatKnownByteCount(bytes)) unified"
        case .dedicated(let bytes):
            return "\(Vitals.formatKnownByteCount(bytes)) dedicated VRAM"
        case .shared(let bytes):
            return "\(Vitals.formatKnownByteCount(bytes)) shared with system"
        }
    }

    // MARK: View

    private var device: GPUDevice? { store.profile?.gpus.first }
    private var latest: GPUSample? { store.gpu?.first }

    public var body: some View {
        HardwarePage(
            title: "GPU",
            vendorName: device?.name,
            showsAppleMark: store.profile?.cpu.isAppleSilicon == true,
            primaryValue: latest?.deviceUtilisation.map { "\(Int(($0 * 100).rounded()))%" },
            series: Self.engineSeries(history: store.gpuHistory),
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            EmptyView()
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.gpu) }
    }

    private var stats: [HardwareStat] {
        [
            HardwareStat(label: "Memory", value: device.map { Self.describeMemory($0.topology) }),
            HardwareStat(label: "In use", value: Vitals.formatByteCount(latest?.inUseMemoryBytes)),
            HardwareStat(label: "Allocated", value: Vitals.formatByteCount(latest?.allocatedMemoryBytes)),
            HardwareStat(
                label: "Renderer",
                value: latest?.rendererUtilisation.map { "\(Int(($0 * 100).rounded()))%" }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        StatRow(label: "Device", value: device?.name)
        StatRow(label: "Cores", value: device?.coreCount.map(String.init))
        StatRow(label: "Tiler", value: latest?.tilerUtilisation.map { "\(Int(($0 * 100).rounded()))%" })
        // Per-process GPU usage needs powermetrics behind the privileged
        // helper, which is milestone M3.
        StatRow(label: "Per-process usage", value: nil)
        ForEach(Array((store.profile?.gpus ?? []).enumerated()), id: \.offset) { index, gpu in
            StatRow(label: "GPU \(index + 1)", value: "\(gpu.name) · \(Self.describeMemory(gpu.topology))")
        }
    }
}
