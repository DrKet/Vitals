import Foundation

extension ChartGeometry {

    /// Builds named MB/s throughput bands from a history of per-device
    /// readings, shared by every page that charts a `[String: Value]` sample
    /// per tick — `StoragePage` (devices) and `NetworkPage` (interfaces).
    ///
    /// A tick's dictionary omits a device/interface entirely rather than
    /// reporting a zero rate for it (see `DiskThroughputTracker` and
    /// `NetworkThroughputTracker`, which drop an entry for the interval
    /// whenever its delta is invalid — the device went away, or its counters
    /// reset). Summing whatever keys are present in that tick's dictionary
    /// already does the right thing: a departed key simply stops
    /// contributing that tick, rather than forcing a fabricated zero into
    /// the sum, and a returning key is summed fresh from its new reading
    /// rather than as a delta against whatever it read before it left.
    ///
    /// `excluding` removes keys from every tick's sum before it is ever
    /// computed — e.g. `NetworkPage`'s loopback interface, which is local
    /// traffic rather than network throughput.
    ///
    /// `bands` is caller-ordered, and that order is load-bearing: the first
    /// band is painted frontmost and is the one a chart's live-value dot
    /// marks, so callers must list bands in on-screen priority order (Storage:
    /// Read before Write; Network: Down before Up), not alphabetically or by
    /// magnitude.
    public static func throughputBands<Value>(
        history: [Timestamped<[String: Value]>],
        excluding: Set<String> = [],
        bands: [(name: String, rate: (Value) -> Double)]
    ) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)
        let bytesPerMegabyte = 1_048_576.0

        return bands.map { band in
            ChartSeries(
                name: band.name,
                values: history.map { entry in
                    entry.sample
                        .filter { !excluding.contains($0.key) }
                        .values
                        .reduce(0) { $0 + band.rate($1) } / bytesPerMegabyte
                },
                timestamps: timestamps,
                unit: .absolute(suffix: "MB/s")
            )
        }
    }
}
