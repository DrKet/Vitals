import Foundation

/// One performance domain. Apple Silicon exposes Performance and Efficiency
/// clusters; Intel machines expose none.
public struct CPUCluster: Sendable, Equatable {
    public let name: String
    public let coreCount: Int
    public let logicalCoreCount: Int

    public init(name: String, coreCount: Int, logicalCoreCount: Int) {
        self.name = name
        self.coreCount = coreCount
        self.logicalCoreCount = logicalCoreCount
    }
}

/// Static description of the processor. Sampled once at launch.
public struct CPUTopology: Sendable, Equatable {
    public let brand: String
    public let physicalCores: Int?
    public let logicalCores: Int?
    public let clusters: [CPUCluster]
    public let l1DataCacheBytes: Int?
    public let l2CacheBytes: Int?
    public let l3CacheBytes: Int?

    /// Apple Silicon reports named performance levels; Intel does not.
    public var isAppleSilicon: Bool { !clusters.isEmpty }

    /// Per-cluster frequency requires IOReport, which is not yet implemented.
    /// Consumers must hide frequency UI while this is `false`.
    public var frequencyAvailable: Bool { false }

    public static func detect(using sysctl: some SysctlProviding) -> CPUTopology {
        var clusters: [CPUCluster] = []
        let levelCount = Int(sysctl.integer("hw.nperflevels") ?? 0)
        for level in 0..<levelCount {
            guard let name = sysctl.string("hw.perflevel\(level).name"),
                  let physical = sysctl.integer("hw.perflevel\(level).physicalcpu")
            else { continue }
            let logical = sysctl.integer("hw.perflevel\(level).logicalcpu") ?? physical
            clusters.append(
                CPUCluster(
                    name: name,
                    coreCount: Int(physical),
                    logicalCoreCount: Int(logical)
                )
            )
        }

        return CPUTopology(
            brand: sysctl.string("machdep.cpu.brand_string") ?? "Unknown Processor",
            physicalCores: sysctl.integer("hw.physicalcpu").map(Int.init),
            logicalCores: sysctl.integer("hw.logicalcpu").map(Int.init),
            clusters: clusters,
            l1DataCacheBytes: sysctl.integer("hw.l1dcachesize").map(Int.init),
            l2CacheBytes: sysctl.integer("hw.l2cachesize").map(Int.init),
            l3CacheBytes: sysctl.integer("hw.l3cachesize").map(Int.init)
        )
    }
}
