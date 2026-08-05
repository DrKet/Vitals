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

    /// A band is emitted only if every tick in `history` has a reading — a
    /// partially-present band would imply measurements the driver never
    /// actually took for the ticks it's missing. Shared by `engineSeries`
    /// (Renderer/Tiler) and `deviceUtilisationSeries` (the Overview tile's
    /// single line) rather than each keeping its own copy of this rule.
    private static func allOrNothingBand(
        name: String,
        history: [Timestamped<[GPUSample]>],
        timestamps: [TimeInterval],
        value: (GPUSample) -> Double?
    ) -> ChartSeries? {
        let values = history.compactMap { entry in entry.sample.first.flatMap(value) }
        guard values.count == history.count else { return nil }
        return ChartSeries(name: name, values: values, timestamps: timestamps)
    }

    /// Renderer and tiler utilisation, per spec §6.3.
    ///
    /// Both fields are optional because which keys a driver publishes varies.
    /// An engine the driver never reported is omitted entirely — a flat 0%
    /// band would claim a measurement that was never taken.
    public static func engineSeries(history: [Timestamped<[GPUSample]>]) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        return [
            allOrNothingBand(name: "Renderer", history: history, timestamps: timestamps) { $0.rendererUtilisation },
            allOrNothingBand(name: "Tiler", history: history, timestamps: timestamps) { $0.tilerUtilisation },
        ].compactMap { $0 }
    }

    /// Overview's GPU tile chart: whole-device utilisation as a single line —
    /// never Renderer+Tiler summed. Those are concurrent engines, not
    /// additive components of a whole; summing them would draw a quantity
    /// the machine never reported, which is exactly what this project's
    /// never-fabricate rule forbids. The tile's own headline
    /// (`OverviewPage.gpuTileValue`) already reads `deviceUtilisation`, so
    /// this is that same number's history — follows the identical
    /// all-or-nothing rule as `engineSeries`, via the same shared helper.
    public static func deviceUtilisationSeries(history: [Timestamped<[GPUSample]>]) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        return [
            allOrNothingBand(name: "GPU", history: history, timestamps: timestamps) { $0.deviceUtilisation }
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

    /// Whether more than one GPU is present, under the general ambiguity
    /// rule that also covers the mirror case: Metal (`gpuCount`, from
    /// `store.profile?.gpus`, `MTLCopyAllDevices()` via `GPUSampler.devices()`)
    /// and IOAccelerator (`sampleCount`, from `store.gpu`, via
    /// `GPUSampler.read()`) are independent enumerations with no identifier
    /// tying either side's entries to the other's, so "the first device" and
    /// "the first sample" are the same physical GPU only by coincidence.
    /// Either enumeration alone reporting more than one device is enough to
    /// make attribution ambiguous — Metal could report a single GPU while
    /// IOAccelerator's latest tick yields two samples (or vice versa), and
    /// naming "the" device would still be pairing a reading with hardware it
    /// might not belong to.
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
    /// A single-array `isMultiGPU(_ gpus:)` convenience overload (fixing
    /// `sampleCount` at 0) used to live here too. A senior review found it
    /// dead in production — nothing called it once `device` was wired
    /// through `attributedDevice(_:sampleCount:)` below, which always passes
    /// the real `store.gpu?.count` — so its own tests were guarding code the
    /// page never executed. Removed rather than kept as an untested-by-production
    /// convenience: this general form is no harder to call correctly, and
    /// every case it covered is exercised directly at its own call sites
    /// below (`GPUPageTests`'s `isMultiGPU(gpuCount:sampleCount:)` cases).
    ///
    /// Internal rather than private so `GPUPageTests` can exercise the guard
    /// directly, without needing to render a full page and inspect pixels.
    static func isMultiGPU(gpuCount: Int, sampleCount: Int) -> Bool {
        gpuCount > 1 || sampleCount > 1
    }

    /// Resolves the one GPU the page may safely name, or `nil` when there is
    /// none or more than one under the *general* ambiguity rule — see
    /// `isMultiGPU(gpuCount:sampleCount:)`'s doc comment for why the mirror
    /// case (one named GPU, more than one IOAccelerator sample this tick) is
    /// exactly as unsafe to name as two named GPUs. `sampleCount` has no
    /// default: `device` below must always pass the real
    /// `store.gpu?.count`, and a call site that could silently default it to
    /// `0` is exactly how this guard went untested against what production
    /// actually runs in the first place — a senior review found `device` had
    /// stopped calling this function entirely, checking only Metal's own
    /// count and missing the mirror case, while every assertion here kept
    /// passing against a version of this function nothing built the page
    /// with. Internal for the same testing reason as `isMultiGPU`.
    static func attributedDevice(_ gpus: [GPUDevice], sampleCount: Int) -> GPUDevice? {
        isMultiGPU(gpuCount: gpus.count, sampleCount: sampleCount) ? nil : gpus.first
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
    ///
    /// Used only by `attributionNotice` below, which needs a plain boolean
    /// (distinct from "no GPU at all", which must not show the notice) —
    /// `device` itself no longer needs this, since it now gets the identical
    /// ambiguity check for free by routing through `attributedDevice(_:sampleCount:)`.
    private var isMultiGPU: Bool {
        Self.isMultiGPU(gpuCount: store.profile?.gpus.count ?? 0, sampleCount: store.gpu?.count ?? 0)
    }

    /// Routed through `attributedDevice(_:sampleCount:)` — the same function
    /// `GPUPageTests` exercises directly — passing the real
    /// `store.gpu?.count` rather than checking only Metal's own count. A
    /// previous version of this computed property called neither: it
    /// re-derived the mirror-case check inline against the instance
    /// `isMultiGPU` above, which was correct but left `attributedDevice`
    /// itself dead in production, so every assertion built on it would have
    /// kept passing even if this property's own gating broke. Wiring through
    /// the same function this file already tests directly is what makes
    /// those assertions load-bearing again.
    ///
    /// Internal rather than private for the same testing reason as
    /// `isMultiGPU`/`attributedDevice` above: a live-store render test can
    /// prove the *chart* stays withheld on an ambiguous tick (that path runs
    /// through the independently-gated `attributableSeries`/`attributableLatest`
    /// below, not through this property at all), without that proving
    /// anything about whether *this* property still forwards the real sample
    /// count rather than a stale or defaulted one — a regression here would
    /// only show up as a wrong device name in the header or a wrong "Memory"
    /// stat, neither of which a pixel-region probe can read. Exposing this
    /// directly is what lets a test catch that regression instead.
    var device: GPUDevice? {
        Self.attributedDevice(store.profile?.gpus ?? [], sampleCount: store.gpu?.count ?? 0)
    }
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
            stacked: true,
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
