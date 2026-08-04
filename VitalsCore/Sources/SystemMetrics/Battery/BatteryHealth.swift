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
