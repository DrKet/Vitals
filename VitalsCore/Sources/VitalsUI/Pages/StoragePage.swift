import SwiftUI
import SystemMetrics

public struct StoragePage: View {
    /// Exposed so `PageConsistencyTests` can verify no two pages share a key —
    /// a shared key would make one page's disclosure expand every other's.
    public static let disclosureKey = "StoragePage.showFullSpecifications"

    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// Read and write throughput per spec §6.3, summed across every device and
    /// expressed in MB/s.
    ///
    /// Built on `ChartGeometry.throughputBands`, which sums whatever devices
    /// are present in each tick's dictionary — see its doc comment for why a
    /// departed device contributes nothing that tick rather than a
    /// fabricated zero, and why a returning one is summed fresh rather than
    /// as a delta against its pre-absence reading.
    ///
    /// The unit is declared rather than inferred: a read rate of 0.05 MB/s must
    /// never be read back as "5%" because it happens to be below 1.
    public static func throughputSeries(
        history: [Timestamped<[String: DiskThroughput]>]
    ) -> [ChartSeries] {
        ChartGeometry.throughputBands(
            history: history,
            bands: [
                (name: "Read", rate: { $0.bytesReadPerSecond }),
                (name: "Write", rate: { $0.bytesWrittenPerSecond }),
            ]
        )
    }

    /// Overview's Storage tile chart: read+write summed per tick into a
    /// single line, in MB/s — the tile's own headline number
    /// (`totalThroughputMBs`/`primaryValue`), never the two stacked bands
    /// above. Built on `ChartGeometry.throughputTotal`, which itself sits on
    /// top of `throughputBands` — the exact tick-filtering `throughputSeries`
    /// above uses, not a second copy of it — so a device excluded/absent this
    /// tick contributes nothing, and a tick with nothing left after that is
    /// dropped rather than summed to a fabricated zero.
    public static func totalThroughputSeries(
        history: [Timestamped<[String: DiskThroughput]>]
    ) -> [ChartSeries] {
        ChartGeometry.throughputTotal(
            history: history,
            name: "Storage",
            rates: [{ $0.bytesReadPerSecond }, { $0.bytesWrittenPerSecond }]
        )
    }

    /// Summed read+write across every device, in MB/s — or `nil` when nothing
    /// has been sampled yet. Internal so Overview's Storage tile (and
    /// `StoragePageTests`) call the same total the page's primary value uses,
    /// rather than re-deriving it and drifting.
    static func totalThroughputMBs(_ diskIO: [String: DiskThroughput]?) -> Double? {
        diskIO.map { devices in
            Vitals.megabytesPerSecond(
                fromBytesPerSecond: devices.values.reduce(0) {
                    $0 + $1.bytesReadPerSecond + $1.bytesWrittenPerSecond
                }
            )
        }
    }

    /// The Storage primary / Overview tile readout, built on
    /// `totalThroughputMBs` so the two views cannot disagree.
    static func primaryValue(_ diskIO: [String: DiskThroughput]?) -> String? {
        totalThroughputMBs(diskIO).map(Vitals.formatMegabytesPerSecond)
    }

    /// Product name for the header vendor-mark slot, from
    /// `HardwareProfile.storageDevices` (via `StorageDeviceParser`).
    ///
    /// A single device is named unconditionally. When several are present,
    /// only a solitary device with a *stated* medium (SSD/HDD) is attributed
    /// — an empty card reader publishing no medium type beside one SSD must
    /// not force an em dash, and two stated media must not pick arbitrarily.
    static func vendorName(devices: [StorageDevice]) -> String? {
        if devices.count == 1 { return devices[0].name }
        let stated = devices.filter { $0.medium == .solidState || $0.medium == .rotational }
        guard stated.count == 1 else { return nil }
        return stated[0].name
    }

    // MARK: View

    /// Latest-only, per `MetricsStore.volumes`: volume capacity changes over
    /// minutes, not seconds, so there is no history to fall back to. An empty
    /// array (rather than `nil`) means "no reading yet" for the views below,
    /// which simply iterate zero times — never a fabricated volume.
    private var volumes: [Volume] { store.volumes ?? [] }

    public var body: some View {
        HardwarePage(
            title: "Storage",
            vendorName: Self.vendorName(devices: store.profile?.storageDevices ?? []),
            showsAppleMark: false,
            primaryValue: Self.primaryValue(store.diskIO),
            series: Self.throughputSeries(history: store.diskIOHistory),
            accent: Vitals.Palette.storage,
            stacked: true,
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(volumes, id: \.name) { volume in
                    VolumeBar(volume: volume, accent: Vitals.Palette.storage)
                }
            }
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.storage) }
        .task { await store.stream(.diskIO) }
    }

    private var stats: [HardwareStat] {
        let boot = volumes.first(where: \.isInternal)
        return [
            // Relies on `storageSampler()` (StandardSamplers.swift) throwing
            // rather than publishing an empty array when no volume is found —
            // otherwise a non-nil-but-empty `store.volumes` would render as
            // "0" here instead of "Unavailable". If that sampler ever starts
            // publishing `[]` for "no reading yet", this needs an explicit
            // `.isEmpty` check.
            HardwareStat(label: "Volumes", value: store.volumes.map { "\($0.count)" }),
            HardwareStat(label: "Capacity", value: Vitals.formatByteCount(boot?.totalBytes)),
            HardwareStat(label: "Available", value: Vitals.formatByteCount(boot?.availableBytes)),
            HardwareStat(
                label: "Read",
                value: store.diskIO.map { devices in
                    Vitals.formatMegabytesPerSecond(
                        Vitals.megabytesPerSecond(
                            fromBytesPerSecond: devices.values.reduce(0) {
                                $0 + $1.bytesReadPerSecond
                            }
                        )
                    )
                }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        ForEach(volumes, id: \.name) { volume in
            StatRow(
                label: volume.name,
                value: "\(Vitals.formatKnownByteCount(volume.usedBytes)) used of \(Vitals.formatKnownByteCount(volume.totalBytes))"
            )
        }
        ForEach(Array((store.diskIO ?? [:]).keys.sorted()), id: \.self) { device in
            StatRow(
                label: device,
                value: (store.diskIO?[device]).map {
                    String(
                        format: "%.2f read · %.2f write MB/s",
                        Vitals.megabytesPerSecond(fromBytesPerSecond: $0.bytesReadPerSecond),
                        Vitals.megabytesPerSecond(fromBytesPerSecond: $0.bytesWrittenPerSecond)
                    )
                }
            )
        }
        // SMART health needs the privileged helper — milestone M3.
        StatRow(label: "SMART health", value: nil)
    }
}
