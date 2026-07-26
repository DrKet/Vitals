import Foundation

/// How a GPU obtains memory. The three cases are reported differently in the
/// UI, so they are modelled distinctly rather than flattened into a byte count.
public enum GPUMemoryTopology: Sendable, Equatable {
    /// Apple Silicon: one pool shared with the CPU.
    case unified(systemBytes: UInt64)
    /// Discrete GPU with its own VRAM.
    case dedicated(vramBytes: UInt64)
    /// Intel integrated graphics carving memory from system RAM.
    case shared(maxSharedBytes: UInt64)
}

public struct GPUDevice: Sendable, Equatable {
    public let name: String
    public let topology: GPUMemoryTopology
    public let coreCount: Int?

    public init(name: String, topology: GPUMemoryTopology, coreCount: Int?) {
        self.name = name
        self.topology = topology
        self.coreCount = coreCount
    }
}

/// Utilisation values are fractions in `0...1`. Every field is optional because
/// which keys `IOAccelerator` publishes varies by driver.
public struct GPUSample: Sendable, Equatable {
    public let deviceUtilisation: Double?
    public let rendererUtilisation: Double?
    public let tilerUtilisation: Double?
    public let inUseMemoryBytes: UInt64?
    public let allocatedMemoryBytes: UInt64?

    public init(
        deviceUtilisation: Double?,
        rendererUtilisation: Double?,
        tilerUtilisation: Double?,
        inUseMemoryBytes: UInt64?,
        allocatedMemoryBytes: UInt64?
    ) {
        self.deviceUtilisation = deviceUtilisation
        self.rendererUtilisation = rendererUtilisation
        self.tilerUtilisation = tilerUtilisation
        self.inUseMemoryBytes = inUseMemoryBytes
        self.allocatedMemoryBytes = allocatedMemoryBytes
    }
}

public enum GPUStatisticsParser {

    private static let recognisedKeys = [
        "Device Utilization %",
        "Renderer Utilization %",
        "Tiler Utilization %",
        "In use system memory",
        "Alloc system memory",
    ]

    /// Returns `nil` when the dictionary contains none of the keys we
    /// understand, so an unrecognised driver reads as unavailable rather than
    /// as a GPU sitting at 0%.
    public static func parse(_ statistics: [String: Any]) -> GPUSample? {
        guard recognisedKeys.contains(where: { statistics[$0] != nil }) else { return nil }

        func percentage(_ key: String) -> Double? {
            guard let raw = statistics[key] as? NSNumber else { return nil }
            return min(max(raw.doubleValue / 100.0, 0), 1)
        }

        func bytes(_ key: String) -> UInt64? {
            guard let raw = statistics[key] as? NSNumber, raw.int64Value >= 0 else { return nil }
            return UInt64(raw.int64Value)
        }

        return GPUSample(
            deviceUtilisation: percentage("Device Utilization %"),
            rendererUtilisation: percentage("Renderer Utilization %"),
            tilerUtilisation: percentage("Tiler Utilization %"),
            inUseMemoryBytes: bytes("In use system memory"),
            allocatedMemoryBytes: bytes("Alloc system memory")
        )
    }
}
