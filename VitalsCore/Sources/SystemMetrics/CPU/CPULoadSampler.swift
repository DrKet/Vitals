import Foundation

/// Fractional time one core spent in each scheduler state over an interval.
/// All values are in `0...1`.
public struct CoreLoad: Sendable, Equatable {
    public let user: Double
    public let system: Double
    public let idle: Double
    public let nice: Double

    public init(user: Double, system: Double, idle: Double, nice: Double) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: Double { user + system + nice }
}

public struct CPULoadSample: Sendable, Equatable {
    public let cores: [CoreLoad]

    public init(cores: [CoreLoad]) {
        self.cores = cores
    }

    /// Mean busy fraction across all cores.
    public var total: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.busy } / Double(cores.count)
    }

    /// Mean busy fraction per named cluster. Clusters are assumed to occupy
    /// contiguous core indices in the order reported by `hw.perflevel*`, which
    /// is how XNU lays them out.
    public func clusterLoads(for clusters: [CPUCluster]) -> [String: Double] {
        var result: [String: Double] = [:]
        var index = 0
        for cluster in clusters {
            let end = min(index + cluster.logicalCoreCount, cores.count)
            guard index < end else { break }
            let slice = cores[index..<end]
            result[cluster.name] = slice.reduce(0) { $0 + $1.busy } / Double(slice.count)
            index = end
        }
        return result
    }
}

/// Uptime and load average — spec §4.1. Read directly rather than sampled on a
/// schedule, since both change slowly.
public struct SystemLoad: Sendable, Equatable {
    public let uptimeSeconds: TimeInterval
    public let loadAverage1: Double?
    public let loadAverage5: Double?
    public let loadAverage15: Double?

    public static func current() -> SystemLoad {
        let averages = loadAverages()
        return SystemLoad(
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            loadAverage1: averages?.0,
            loadAverage5: averages?.1,
            loadAverage15: averages?.2
        )
    }

    /// `getloadavg` is the supported interface and needs no sysctl plumbing.
    /// Returns `nil` if the call fails. Note that `0` is a valid result from
    /// a successfully idle system; `nil` specifically indicates the call failed,
    /// not that the load average is actually zero.
    private static func loadAverages() -> (Double, Double, Double)? {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return nil }
        return (averages[0], averages[1], averages[2])
    }
}

/// Converts two tick readings into a load sample. Pure, and therefore the part
/// that carries the test coverage.
public enum CPULoadCalculator {
    public static func load(from previous: [CPUTicks], to current: [CPUTicks]) -> CPULoadSample? {
        guard !current.isEmpty, previous.count == current.count else { return nil }

        var cores: [CoreLoad] = []
        cores.reserveCapacity(current.count)

        for (before, after) in zip(previous, current) {
            // A decreasing counter means a reset or wraparound.
            guard after.total >= before.total,
                  after.user >= before.user,
                  after.system >= before.system,
                  after.idle >= before.idle,
                  after.nice >= before.nice
            else { return nil }

            let elapsed = after.total - before.total
            guard elapsed > 0 else {
                cores.append(CoreLoad(user: 0, system: 0, idle: 1, nice: 0))
                continue
            }

            let divisor = Double(elapsed)
            cores.append(
                CoreLoad(
                    user: Double(after.user - before.user) / divisor,
                    system: Double(after.system - before.system) / divisor,
                    idle: Double(after.idle - before.idle) / divisor,
                    nice: Double(after.nice - before.nice) / divisor
                )
            )
        }

        return CPULoadSample(cores: cores)
    }
}
