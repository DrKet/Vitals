import Foundation

/// Raw page counts from the VM subsystem, plus the page size needed to convert
/// them to bytes.
public struct VMCounters: Sendable, Equatable {
    public var free: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var internalPages: UInt64
    public var pageSize: UInt64

    public init(
        free: UInt64,
        wired: UInt64,
        compressed: UInt64,
        purgeable: UInt64,
        external: UInt64,
        internalPages: UInt64,
        pageSize: UInt64
    ) {
        self.free = free
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
        self.internalPages = internalPages
        self.pageSize = pageSize
    }
}

public enum MemoryPressure: Sendable, Equatable {
    case normal
    case warning
    case critical
}

/// All values in bytes.
public struct MemorySample: Sendable, Equatable {
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64
    public let free: UInt64

    /// `nil` when the swap sysctl could not be read. Never `0` for an
    /// unreadable value — zero means genuinely no swap in use.
    public let swapUsed: UInt64?
    public let swapTotal: UInt64?

    /// `nil` when the pressure level could not be read or was unrecognised.
    public let pressure: MemoryPressure?

    /// Matches Activity Monitor's "Memory Used".
    public var used: UInt64 { app + wired + compressed }
}

public enum MemoryCalculator {
    public static func sample(
        from counters: VMCounters,
        swapUsed: UInt64?,
        swapTotal: UInt64?,
        pressure: MemoryPressure?
    ) -> MemorySample {
        let page = counters.pageSize

        // Purgeable pages are internal but reclaimable, so they belong to the
        // file cache rather than to app memory. Subtracting them here is what
        // keeps them from being counted in both buckets.
        let appPages = counters.internalPages >= counters.purgeable
            ? counters.internalPages - counters.purgeable
            : 0

        return MemorySample(
            app: appPages * page,
            wired: counters.wired * page,
            compressed: counters.compressed * page,
            cached: (counters.external + counters.purgeable) * page,
            free: counters.free * page,
            swapUsed: swapUsed,
            swapTotal: swapTotal,
            pressure: pressure
        )
    }
}
