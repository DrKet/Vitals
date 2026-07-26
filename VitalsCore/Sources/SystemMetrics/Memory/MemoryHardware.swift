import Foundation

/// One physical DIMM. Only present on machines with discrete memory modules.
public struct MemorySlot: Sendable, Equatable {
    public let name: String
    public let sizeDescription: String
    public let type: String?
    public let speedMHz: Int?
    public let manufacturer: String?
    public let partNumber: String?

    public init(
        name: String,
        sizeDescription: String,
        type: String?,
        speedMHz: Int?,
        manufacturer: String?,
        partNumber: String?
    ) {
        self.name = name
        self.sizeDescription = sizeDescription
        self.type = type
        self.speedMHz = speedMHz
        self.manufacturer = manufacturer
        self.partNumber = partNumber
    }
}

public struct MemoryHardware: Sendable, Equatable {
    public let totalBytes: UInt64
    public let type: String?
    public let manufacturer: String?
    public let isUnified: Bool
    public let slots: [MemorySlot]

    /// Published SoC bandwidth in GB/s. Present only on recognised Apple
    /// Silicon. This is a specification figure and must be labelled as such.
    public let peakBandwidthGBs: Double?

    /// Real memory clock. Available on Intel Macs, which expose per-DIMM SPD
    /// data. Always `nil` on Apple Silicon, which exposes no clock at all —
    /// see spec §4.2. Never synthesise a value for this field.
    public var speedMHz: Int? { slots.first?.speedMHz }
}

public enum MemoryHardwareError: Error {
    case malformedProfilerOutput
}

public enum MemoryHardwareParser {

    public static func parse(
        profilerJSON: Data,
        totalBytes: UInt64,
        isUnified: Bool,
        brand: String
    ) throws -> MemoryHardware {
        guard
            let root = try? JSONSerialization.jsonObject(with: profilerJSON) as? [String: Any],
            let entries = root["SPMemoryDataType"] as? [[String: Any]],
            let first = entries.first
        else {
            throw MemoryHardwareError.malformedProfilerOutput
        }

        let slots = (first["_items"] as? [[String: Any]] ?? []).map(parseSlot)

        return MemoryHardware(
            totalBytes: totalBytes,
            type: first["dimm_type"] as? String ?? slots.first?.type,
            manufacturer: first["dimm_manufacturer"] as? String ?? slots.first?.manufacturer,
            isUnified: isUnified,
            slots: slots,
            peakBandwidthGBs: isUnified ? SoCBandwidth.peakGBs(forBrand: brand) : nil
        )
    }

    private static func parseSlot(_ item: [String: Any]) -> MemorySlot {
        MemorySlot(
            name: item["_name"] as? String ?? "Unknown",
            sizeDescription: item["dimm_size"] as? String ?? "Unknown",
            type: item["dimm_type"] as? String,
            speedMHz: (item["dimm_speed"] as? String).flatMap(parseMegahertz),
            manufacturer: item["dimm_manufacturer"] as? String,
            partNumber: item["dimm_part_number"] as? String
        )
    }

    /// `"2667 MHz"` becomes `2667`. Anything unparseable becomes `nil` rather
    /// than a default.
    private static func parseMegahertz(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
