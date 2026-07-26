import Foundation

public enum StorageMedium: Sendable, Equatable {
    case solidState
    case rotational
    /// The device did not state its medium. Reported as unknown rather than
    /// assumed, since guessing wrong misdescribes the user's hardware.
    case unknown
}

public struct StorageDevice: Sendable, Equatable {
    public let name: String
    public let medium: StorageMedium
    public let interconnect: String?
    public let revision: String?
}

public struct Volume: Sendable, Equatable {
    public let name: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let isInternal: Bool

    public init(name: String, totalBytes: UInt64, availableBytes: UInt64, isInternal: Bool) {
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isInternal = isInternal
    }

    public var usedBytes: UInt64 {
        totalBytes >= availableBytes ? totalBytes - availableBytes : 0
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

public struct StorageIOCounters: Sendable, Equatable {
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

/// Read and write throughput for one block device, in bytes per second.
public struct DiskThroughput: Sendable, Equatable {
    public let bytesReadPerSecond: Double
    public let bytesWrittenPerSecond: Double

    public init(bytesReadPerSecond: Double, bytesWrittenPerSecond: Double) {
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
    }
}

/// Turns cumulative per-device byte counters into throughput.
///
/// One `DeltaCounter` per device per direction, mirroring
/// `NetworkThroughputTracker`: devices come and go (external drives, disk
/// images), and a shared counter would let one device's disappearance corrupt
/// another's rate.
public struct DiskThroughputTracker: Sendable {
    private var read: [String: DeltaCounter<UInt64>] = [:]
    private var written: [String: DeltaCounter<UInt64>] = [:]

    public init() {}

    public mutating func update(
        _ counters: [String: StorageIOCounters],
        at timestamp: TimeInterval
    ) -> [String: DiskThroughput] {
        var result: [String: DiskThroughput] = [:]

        for (device, counter) in counters {
            var readCounter = read[device] ?? DeltaCounter<UInt64>()
            var writeCounter = written[device] ?? DeltaCounter<UInt64>()

            let readDelta = readCounter.update(counter.bytesRead, at: timestamp)
            let writeDelta = writeCounter.update(counter.bytesWritten, at: timestamp)

            read[device] = readCounter
            written[device] = writeCounter

            // Both directions must be valid; a reset on either invalidates the
            // interval for this device rather than reporting half a reading.
            if let readDelta, let writeDelta {
                result[device] = DiskThroughput(
                    bytesReadPerSecond: readDelta.perSecond,
                    bytesWrittenPerSecond: writeDelta.perSecond
                )
            }
        }

        // Forget departed devices so a reappearance starts fresh instead of
        // producing a huge delta against a stale reading.
        read = read.filter { counters.keys.contains($0.key) }
        written = written.filter { counters.keys.contains($0.key) }

        return result
    }
}

public enum StorageDeviceParser {
    public static func parse(
        deviceCharacteristics: [String: Any],
        protocolCharacteristics: [String: Any]
    ) -> StorageDevice? {
        guard let name = deviceCharacteristics["Product Name"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }

        let medium: StorageMedium
        switch deviceCharacteristics["Medium Type"] as? String {
        case "Solid State": medium = .solidState
        case "Rotational": medium = .rotational
        default: medium = .unknown
        }

        return StorageDevice(
            name: name.trimmingCharacters(in: .whitespaces),
            medium: medium,
            interconnect: protocolCharacteristics["Physical Interconnect"] as? String,
            revision: deviceCharacteristics["Product Revision Level"] as? String
        )
    }
}
