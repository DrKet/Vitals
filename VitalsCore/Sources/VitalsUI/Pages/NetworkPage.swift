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

    /// `throughput` with excluded interfaces removed, or `nil` when nothing
    /// is left afterwards — e.g. a tick whose only entry was loopback.
    ///
    /// Distinguishing that from "real interfaces present but reporting zero"
    /// is exactly the ambiguity `ThroughputBands` already guards the chart
    /// against (see its doc comment): reducing an empty dictionary would
    /// silently produce a real-looking `0.00 MB/s`, claiming every interface
    /// reported no traffic when in fact none reported at all that tick.
    /// `totalMBs` and the Down/Up stats below must not disagree with the
    /// chart they sit above — a tick the chart omits must not headline as a
    /// measured zero underneath it.
    ///
    /// Internal rather than private so `NetworkPageTests` can exercise the
    /// nil-vs-empty distinction directly, the same reason `GPUPage.isMultiGPU`
    /// and `CPUPage.gatedValue` are internal.
    static func realThroughput(_ throughput: [String: NetworkThroughput]) -> [String: NetworkThroughput]? {
        let real = throughput.filter { !excludedInterfaces.contains($0.key) }
        return real.isEmpty ? nil : real
    }

    /// The "Active interfaces" stat's display value, gated on `realThroughput`
    /// — the same filtered set Down and Up are gated on — rather than merely
    /// on `throughput != nil`.
    ///
    /// A senior review found the previous gate let an lo0-only tick
    /// (`throughput` non-nil, but every entry excluded) fall through to a
    /// real-looking `"0"`: `realThroughput` was nil (correctly producing
    /// "Unavailable" for Down/Up from the same tick), while this stat still
    /// computed `activeInterfaces(current).count`, landing on `0` — a
    /// bright, primary-styled zero sitting directly above two "Unavailable"
    /// rows drawn from the exact same empty filtered set. Routing through
    /// `realThroughput` first makes the three stats agree on when a tick has
    /// nothing real to report at all.
    ///
    /// A real, non-empty set of non-excluded interfaces that simply carried
    /// no traffic this tick is still a genuine `"0"` (see `activeInterfaces`'s
    /// doc comment) — only presence vs. absence of *any* real interface is
    /// decided here; the count itself still comes from `activeInterfaces`,
    /// which applies the traffic filter `realThroughput` does not.
    ///
    /// Internal for the same testing reason as `realThroughput` above.
    static func activeInterfaceCountDisplay(_ throughput: [String: NetworkThroughput]?) -> String? {
        guard let throughput, Self.realThroughput(throughput) != nil else { return nil }
        return "\(Self.activeInterfaces(throughput).count)"
    }

    private var totalMBs: Double? {
        guard let network = store.network, let real = Self.realThroughput(network) else { return nil }
        return real.values.reduce(0) { $0 + $1.bytesInPerSecond + $1.bytesOutPerSecond } / Self.bytesPerMegabyte
    }

    public var body: some View {
        HardwarePage(
            title: "Network",
            vendorName: Self.activeInterfaces(current).first,
            showsAppleMark: false,
            primaryValue: totalMBs.map { String(format: "%.2f MB/s", $0) },
            series: Self.throughputSeries(history: store.networkHistory),
            accent: Vitals.Palette.network,
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
                // See `activeInterfaceCountDisplay`'s doc comment for why
                // this is gated on `realThroughput` rather than on
                // `store.network == nil` alone.
                value: Self.activeInterfaceCountDisplay(store.network)
            ),
            HardwareStat(
                label: "Down",
                value: store.network.flatMap(Self.realThroughput).map { real in
                    String(
                        format: "%.2f MB/s",
                        real.values.reduce(0) { $0 + $1.bytesInPerSecond } / Self.bytesPerMegabyte
                    )
                }
            ),
            HardwareStat(
                label: "Up",
                value: store.network.flatMap(Self.realThroughput).map { real in
                    String(
                        format: "%.2f MB/s",
                        real.values.reduce(0) { $0 + $1.bytesOutPerSecond } / Self.bytesPerMegabyte
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
