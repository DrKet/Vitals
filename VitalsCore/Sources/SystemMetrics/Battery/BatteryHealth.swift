import Foundation

/// Apple's own verdict on the battery, read rather than derived.
///
/// Maximum Capacity is not computed from IORegistry values on purpose: Apple
/// reports 95% on this machine, while `AppleRawMaxCapacity / DesignCapacity`
/// gives 90.4% and `NominalChargeCapacity / DesignCapacity` gives 92.9%.
/// Apple's own formula is undocumented, so a figure that contradicts Settings
/// is worse than showing none — this reads `system_profiler`'s verdict
/// instead of picking one of the two disagreeing formulas.
public struct BatteryHealth: Sendable, Equatable {
    /// Verbatim from `sppower_battery_health`, e.g. "Good".
    ///
    /// Shown as-is. `system_profiler`'s text output and Settings say "Normal"
    /// for this same state, but only one health state has ever been observed
    /// on one machine, so translating would be inventing a mapping.
    public let condition: String
    /// `nil` when the reported string cannot be parsed. Never 0 — a battery
    /// reporting 0% maximum capacity would be a broken measurement, not a
    /// broken battery.
    public let maximumCapacityPercent: Int?
    public let cycleCount: Int?

    public init(condition: String, maximumCapacityPercent: Int?, cycleCount: Int?) {
        self.condition = condition
        self.maximumCapacityPercent = maximumCapacityPercent
        self.cycleCount = cycleCount
    }
}

public enum BatteryHealthParser {
    /// `nil` when the payload contains no battery block at all — a desktop Mac.
    public static func parse(profilerJSON data: Data) throws -> BatteryHealth? {
        struct Payload: Decodable {
            let SPPowerDataType: [Item]
            struct Item: Decodable {
                let _name: String
                let sppower_battery_health_info: HealthInfo?
                struct HealthInfo: Decodable {
                    let sppower_battery_cycle_count: Int?
                    let sppower_battery_health: String?
                    let sppower_battery_health_maximum_capacity: String?
                }
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let info = payload.SPPowerDataType
            .first(where: { $0._name == "spbattery_information" })?
            .sppower_battery_health_info,
            let condition = info.sppower_battery_health
        else { return nil }

        // "95%" — strip the suffix rather than assuming a number.
        let capacity = info.sppower_battery_health_maximum_capacity
            .flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }

        return BatteryHealth(
            condition: condition,
            maximumCapacityPercent: capacity,
            cycleCount: info.sppower_battery_cycle_count
        )
    }
}

enum BatteryHealthReaderError: Error, Equatable {
    case powerProfilerFailed(status: Int32)
}

/// Owns the `system_profiler` spawn behind `BatteryHealth`.
///
/// Kept separate from `HardwareProfile`, which only carries `hasBattery`: the
/// profiler subprocess is slow, and health figures change over months rather
/// than being fixed at launch, so `MetricsStore` reads through here once,
/// lazily, the first time a battery sample arrives — not for every machine on
/// every launch.
public enum BatteryHealthReader {
    /// `nil` for a desktop Mac (no battery) or when `system_profiler` fails.
    /// Throwing here would make a routine absence — most Macs in a fleet are
    /// desktops — indistinguishable from a real subprocess failure to the
    /// caller, so both collapse to the same `nil`.
    public static func read() -> BatteryHealth? {
        guard let data = try? powerProfilerOutput() else { return nil }
        return try? BatteryHealthParser.parse(profilerJSON: data)
    }

    /// Mirrors `HardwareProfile.memoryProfilerOutput()` exactly — same
    /// drain-before-wait and same non-zero-exit throw — but its only caller,
    /// `read()`, swallows the throw into `nil` rather than propagating it: a
    /// battery read is not load-bearing for the rest of the app the way
    /// memory is.
    private static func powerProfilerOutput() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPPowerDataType"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Read before waiting: draining the pipe as the child writes is what
        // keeps a large payload from filling the kernel buffer and deadlocking.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // A non-zero exit can still leave partial output on stdout. Treating
        // that as a successful read would let degraded data through as though
        // it were a clean measurement.
        guard process.terminationStatus == 0 else {
            throw BatteryHealthReaderError.powerProfilerFailed(status: process.terminationStatus)
        }

        return data
    }
}
