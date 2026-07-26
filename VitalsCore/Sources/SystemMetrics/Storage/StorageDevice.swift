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
