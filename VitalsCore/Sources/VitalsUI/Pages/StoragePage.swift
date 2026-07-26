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
    /// A tick's dictionary omits a device entirely rather than reporting a
    /// zero rate for it (see `DiskThroughputTracker`), so summing whatever
    /// devices are present in that tick's dictionary already does the right
    /// thing — a departed device simply stops contributing, rather than
    /// forcing a fabricated zero into the sum.
    ///
    /// The unit is declared rather than inferred: a read rate of 0.05 MB/s must
    /// never be read back as "5%" because it happens to be below 1.
    public static func throughputSeries(
        history: [Timestamped<[String: DiskThroughput]>]
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        func band(_ name: String, _ value: @escaping (DiskThroughput) -> Double) -> ChartSeries {
            ChartSeries(
                name: name,
                values: history.map { entry in
                    entry.sample.values.reduce(0) { $0 + value($1) } / bytesPerMegabyte
                },
                timestamps: timestamps,
                unit: .absolute(suffix: "MB/s")
            )
        }

        return [
            band("Read") { $0.bytesReadPerSecond },
            band("Write") { $0.bytesWrittenPerSecond },
        ]
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

    /// `Volume`'s byte counts are plain `UInt64`s, never optional — same
    /// reasoning as `VolumeBar.format` — so this always takes
    /// `Vitals.formatByteCount`'s non-nil branch.
    private static func formatVolumeBytes(_ bytes: UInt64) -> String {
        Vitals.formatByteCount(bytes)!
    }

    private var stats: [HardwareStat] {
        let boot = volumes.first(where: \.isInternal)
        return [
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
                value: "\(Self.formatVolumeBytes(volume.usedBytes)) used of \(Self.formatVolumeBytes(volume.totalBytes))"
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
