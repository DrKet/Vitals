import SwiftUI
import SystemMetrics

public struct NetworkPage: View {
    /// Exposed so `PageConsistencyTests` can verify no two pages share a key —
    /// a shared key would make one page's disclosure expand every other's.
    public static let disclosureKey = "NetworkPage.showFullSpecifications"

    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    private static let bytesPerMegabyte = 1_048_576.0

    /// Loopback carries local traffic between processes on this machine. It is
    /// not network throughput, and including it would swamp the chart whenever
    /// anything talks to a local service.
    private static let excludedInterfaces: Set<String> = ["lo0"]

    /// Down and up throughput per spec §6.3, summed across every real
    /// interface and expressed in MB/s, loopback excluded.
    ///
    /// Built on `ChartGeometry.throughputBands`, which sums whatever
    /// interfaces are present in each tick's dictionary — see its doc
    /// comment for why a departed interface contributes nothing that tick
    /// rather than a fabricated zero, and why a returning one is summed
    /// fresh rather than as a delta against its pre-absence reading.
    public static func throughputSeries(
        history: [Timestamped<[String: NetworkThroughput]>]
    ) -> [ChartSeries] {
        ChartGeometry.throughputBands(
            history: history,
            excluding: excludedInterfaces,
            bands: [
                (name: "Down", rate: { $0.bytesInPerSecond }),
                (name: "Up", rate: { $0.bytesOutPerSecond }),
            ]
        )
    }

    /// Interfaces currently carrying traffic, loopback excluded. An idle
    /// interface is omitted rather than listed at zero — a Mac has many.
    public static func activeInterfaces(_ throughput: [String: NetworkThroughput]) -> [String] {
        throughput
            .filter { !excludedInterfaces.contains($0.key) }
            .filter { $0.value.bytesInPerSecond > 0 || $0.value.bytesOutPerSecond > 0 }
            .keys
            .sorted()
    }

    // MARK: View

    private var current: [String: NetworkThroughput] { store.network ?? [:] }

    private var totalMBs: Double? {
        guard store.network != nil else { return nil }
        return current
            .filter { !Self.excludedInterfaces.contains($0.key) }
            .values
            .reduce(0) { $0 + $1.bytesInPerSecond + $1.bytesOutPerSecond } / Self.bytesPerMegabyte
    }

    public var body: some View {
        HardwarePage(
            title: "Network",
            vendorName: Self.activeInterfaces(current).first,
            showsAppleMark: false,
            primaryValue: totalMBs.map { String(format: "%.2f MB/s", $0) },
            series: Self.throughputSeries(history: store.networkHistory),
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            EmptyView()
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.network) }
    }

    private var stats: [HardwareStat] {
        [
            HardwareStat(
                label: "Active interfaces",
                // `store.network == nil` (never sampled) must read
                // "Unavailable"; `store.network == [:]` or all-idle (a real
                // reading of zero active interfaces) must read "0" — an
                // `active.isEmpty` check alone cannot tell those apart.
                value: store.network == nil ? nil : "\(Self.activeInterfaces(current).count)"
            ),
            HardwareStat(
                label: "Down",
                value: store.network.map { throughput in
                    String(
                        format: "%.2f MB/s",
                        throughput.filter { !Self.excludedInterfaces.contains($0.key) }
                            .values.reduce(0) { $0 + $1.bytesInPerSecond } / Self.bytesPerMegabyte
                    )
                }
            ),
            HardwareStat(
                label: "Up",
                value: store.network.map { throughput in
                    String(
                        format: "%.2f MB/s",
                        throughput.filter { !Self.excludedInterfaces.contains($0.key) }
                            .values.reduce(0) { $0 + $1.bytesOutPerSecond } / Self.bytesPerMegabyte
                    )
                }
            ),
            // Wi-Fi SSID and signal need CoreWLAN, whose SSID access requires
            // location authorisation — deferred with the menu bar work.
            HardwareStat(label: "Wi-Fi", value: nil),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        ForEach(Self.activeInterfaces(current), id: \.self) { name in
            StatRow(
                label: name,
                value: current[name].map {
                    String(
                        format: "%.2f down · %.2f up MB/s",
                        $0.bytesInPerSecond / Self.bytesPerMegabyte,
                        $0.bytesOutPerSecond / Self.bytesPerMegabyte
                    )
                }
            )
        }
        // Per-process network attribution for other users' processes needs the
        // privileged helper — milestone M3.
        StatRow(label: "Per-process traffic", value: nil)
    }
}
