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

    /// The general form of `isMultiGPU(_:)` above, also covering the mirror
    /// case: Metal (`gpuCount`, from `store.profile?.gpus`) and IOAccelerator
    /// (`sampleCount`, from `store.gpu`) are independent enumerations, so
    /// either one alone reporting more than one device is enough to make
    /// attribution ambiguous — Metal could report a single GPU while
    /// IOAccelerator's latest tick yields two samples (or vice versa), and
    /// naming "the" device would still be pairing a reading with hardware it
    /// might not belong to. `isMultiGPU(_:)` is the special case of this with
    /// `sampleCount` fixed at 0, which is why it can stay written the way it
    /// already was rather than being reimplemented here.
    ///
    /// Internal for the same testing reason as `isMultiGPU(_:)`.
    static func isMultiGPU(gpuCount: Int, sampleCount: Int) -> Bool {
        gpuCount > 1 || sampleCount > 1
    }

    /// Resolves the one GPU the page may safely name, or `nil` when there is
    /// none or more than one — see `isMultiGPU`'s doc comment for why more
    /// than one can never be named. Internal for the same testing reason as
    /// `isMultiGPU`.
    static func attributedDevice(_ gpus: [GPUDevice]) -> GPUDevice? {
        isMultiGPU(gpus) ? nil : gpus.first
    }

    /// `latest`, but withheld once either enumeration reports more than one
    /// device — see `isMultiGPU(gpuCount:sampleCount:)`. Internal so
    /// `GPUPageTests` can verify the primary reading and chart series are
    /// gated by the exact same rule as the stat rows, without rendering a
    /// full page.
    static func attributableLatest(_ latest: GPUSample?, gpuCount: Int, sampleCount: Int) -> GPUSample? {
        isMultiGPU(gpuCount: gpuCount, sampleCount: sampleCount) ? nil : latest
    }

    /// `series`, but withheld under the same ambiguity. A chart labelled
    /// "Renderer"/"Tiler" drawn from an arbitrarily-picked sample would
    /// contradict the stat rows immediately below it reading "Unavailable"
    /// for the same engines — see this file's top-level doc comment. Internal
    /// for the same testing reason as `attributableLatest`.
    static func attributableSeries(_ series: [ChartSeries], gpuCount: Int, sampleCount: Int) -> [ChartSeries] {
        isMultiGPU(gpuCount: gpuCount, sampleCount: sampleCount) ? [] : series
    }

    /// Neither Metal's nor IOAccelerator's own count in isolation: covers the
    /// mirror case (`GPUPage.swift`'s doc comment for `isMultiGPU`) where one
    /// enumeration reports a single device this tick but the other reports
    /// more than one — attribution is just as broken either way round.
    private var isMultiGPU: Bool {
        Self.isMultiGPU(gpuCount: store.profile?.gpus.count ?? 0, sampleCount: store.gpu?.count ?? 0)
    }

    /// Named directly from `store.profile?.gpus`, not through
    /// `attributedDevice(_:)`: that overload only ever sees Metal's own
    /// count, so on the mirror case (Metal reports one device, IOAccelerator
    /// reports more than one this tick) it would still name the lone Metal
    /// device — exactly the bug this fix closes. Gating on the instance
    /// `isMultiGPU` above, which also looks at `store.gpu`'s count, is what
    /// catches that case.
    private var device: GPUDevice? { isMultiGPU ? nil : store.profile?.gpus.first }
    private var latest: GPUSample? { store.gpu?.first }

    /// `latest`, but withheld on a multi-GPU Mac. `device` above already
    /// keeps the page from naming a device it cannot attribute; this keeps
    /// it from pairing that same ambiguous sample with the "Memory" / "In
    /// use" / "Allocated" / "Renderer" / "Tiler" readings either, since those
    /// carry the identical device-vs-sample ambiguity as `device` does.
    private var attributableLatest: GPUSample? {
        Self.attributableLatest(latest, gpuCount: store.profile?.gpus.count ?? 0, sampleCount: store.gpu?.count ?? 0)
    }

    public var body: some View {
        HardwarePage(
            title: "GPU",
            vendorName: device?.name,
            showsAppleMark: store.profile?.cpu.isAppleSilicon == true,
            // Both gated on the identical ambiguity the stats already are —
            // see `attributableLatest`/`attributableSeries`'s doc comments.
            // A chart labelled "Renderer" and a bare percentage under a badge
            // deliberately withheld would otherwise present one arbitrary
            // GPU's load as the whole machine's.
            primaryValue: attributableLatest?.deviceUtilisation.map { "\(Int(($0 * 100).rounded()))%" },
            series: Self.attributableSeries(
                Self.engineSeries(history: store.gpuHistory),
                gpuCount: store.profile?.gpus.count ?? 0,
                sampleCount: store.gpu?.count ?? 0
            ),
            accent: Vitals.Palette.gpu,
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            attributionNotice
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.gpu) }
    }

    /// Explains the otherwise-mostly-empty page on a multi-GPU Mac, rather
    /// than leaving it silently blank. Follows `CPUPage`'s convention for a
    /// structurally-unavailable reading: a row that stays on screen and
    /// states what is missing, styled as secondary/de-emphasised content,
    /// instead of the section simply vanishing and leaving the reader to
    /// guess whether the app is broken.
    @ViewBuilder
    private var attributionNotice: some View {
        if isMultiGPU {
            Text(
                "This Mac reports more than one GPU, and nothing ties a reading to a specific device — so utilisation and memory are withheld here rather than shown against the wrong one."
            )
            .font(Vitals.Typography.label)
            .foregroundStyle(.secondary)
        }
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
