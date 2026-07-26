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

    /// Whether more than one GPU is present.
    ///
    /// `device` (below) walks `store.profile?.gpus`, which is Metal's
    /// enumeration order (`MTLCopyAllDevices()`, see `GPUSampler.devices()`).
    /// `latest` walks `store.gpu`, which is IOAccelerator's iteration order
    /// (`GPUSampler.read()`). Neither array carries an identifier tying its
    /// entries to the other's, so "the first device" and "the first sample"
    /// are the same physical GPU only by coincidence.
    ///
    /// On a single-GPU Mac — the case on this machine, and on every Apple
    /// Silicon Mac — there is exactly one candidate on each side, so the
    /// coincidence always holds. On a Mac with more than one GPU (an Intel
    /// iGPU plus a discrete card, or an eGPU) it can silently fail: naming
    /// device A in the header while showing device B's memory and
    /// utilisation numbers underneath it would attribute a real measurement
    /// to the wrong piece of hardware, which is as dishonest as fabricating
    /// the number outright. Fixing this properly needs a device identifier
    /// threaded through `GPUSample`, which is out of scope here.
    ///
    /// Internal rather than private so `GPUPageTests` can exercise the guard
    /// directly, without needing to render a full page and inspect pixels.
    static func isMultiGPU(_ gpus: [GPUDevice]) -> Bool { gpus.count > 1 }

    /// Resolves the one GPU the page may safely name, or `nil` when there is
    /// none or more than one — see `isMultiGPU`'s doc comment for why more
    /// than one can never be named. Internal for the same testing reason as
    /// `isMultiGPU`.
    static func attributedDevice(_ gpus: [GPUDevice]) -> GPUDevice? {
        isMultiGPU(gpus) ? nil : gpus.first
    }

    private var isMultiGPU: Bool { Self.isMultiGPU(store.profile?.gpus ?? []) }
    private var device: GPUDevice? { Self.attributedDevice(store.profile?.gpus ?? []) }
    private var latest: GPUSample? { store.gpu?.first }

    /// `latest`, but withheld on a multi-GPU Mac. `device` above already
    /// keeps the page from naming a device it cannot attribute; this keeps
    /// it from pairing that same ambiguous sample with the "Memory" / "In
    /// use" / "Allocated" / "Renderer" / "Tiler" readings either, since those
    /// carry the identical device-vs-sample ambiguity as `device` does.
    private var attributableLatest: GPUSample? { isMultiGPU ? nil : latest }

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
            HardwareStat(label: "In use", value: Vitals.formatByteCount(attributableLatest?.inUseMemoryBytes)),
            HardwareStat(
                label: "Allocated",
                value: Vitals.formatByteCount(attributableLatest?.allocatedMemoryBytes)
            ),
            HardwareStat(
                label: "Renderer",
                value: attributableLatest?.rendererUtilisation.map { "\(Int(($0 * 100).rounded()))%" }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        StatRow(label: "Device", value: device?.name)
        StatRow(label: "Cores", value: device?.coreCount.map(String.init))
        StatRow(
            label: "Tiler",
            value: attributableLatest?.tilerUtilisation.map { "\(Int(($0 * 100).rounded()))%" }
        )
        // Per-process GPU usage needs powermetrics behind the privileged
        // helper, which is milestone M3.
        StatRow(label: "Per-process usage", value: nil)
        ForEach(Array((store.profile?.gpus ?? []).enumerated()), id: \.offset) { index, gpu in
            StatRow(label: "GPU \(index + 1)", value: "\(gpu.name) · \(Self.describeMemory(gpu.topology))")
        }
    }
}
