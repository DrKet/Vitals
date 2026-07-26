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

    private static let bytesPerMegabyte = 1_048_576.0

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

    // MARK: View

    /// Latest-only, per `MetricsStore.volumes`: volume capacity changes over
    /// minutes, not seconds, so there is no history to fall back to. An empty
    /// array (rather than `nil`) means "no reading yet" for the views below,
    /// which simply iterate zero times — never a fabricated volume.
    private var volumes: [Volume] { store.volumes ?? [] }

    private var totalThroughput: Double? {
        store.diskIO.map { devices in
            devices.values.reduce(0) { $0 + $1.bytesReadPerSecond + $1.bytesWrittenPerSecond }
                / Self.bytesPerMegabyte
        }
    }

    public var body: some View {
        HardwarePage(
            title: "Storage",
            vendorName: volumes.first(where: \.isInternal)?.name,
            showsAppleMark: false,
            primaryValue: totalThroughput.map { String(format: "%.2f MB/s", $0) },
            series: Self.throughputSeries(history: store.diskIOHistory),
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
                    String(
                        format: "%.2f MB/s",
                        devices.values.reduce(0) { $0 + $1.bytesReadPerSecond } / Self.bytesPerMegabyte
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
                        $0.bytesReadPerSecond / Self.bytesPerMegabyte,
                        $0.bytesWrittenPerSecond / Self.bytesPerMegabyte
                    )
                }
            )
        }
        // SMART health needs the privileged helper — milestone M3.
        StatRow(label: "SMART health", value: nil)
    }
}
