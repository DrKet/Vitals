import Foundation
import Testing
@testable import SystemMetrics

@Suite("Battery health")
struct BatteryHealthTests {

    /// Captured verbatim from `system_profiler -json SPPowerDataType` on a
    /// Mac14,9. Note `sppower_battery_health` is "Good" here while the tool's
    /// own TEXT output — and Settings — say "Normal". That divergence is
    /// accepted, not mapped: only one health state has ever been observed, so
    /// any translation table beyond it would be invented.
    private static let realJSON = Data("""
    {"SPPowerDataType":[{"_name":"spbattery_information",
      "sppower_battery_charge_info":{"sppower_battery_state_of_charge":36},
      "sppower_battery_health_info":{"sppower_battery_cycle_count":128,
        "sppower_battery_health":"Good",
        "sppower_battery_health_maximum_capacity":"95%"}}]}
    """.utf8)

    @Test("health is read from the profiler, never computed")
    func parsesRealOutput() throws {
        let health = try #require(try BatteryHealthParser.parse(profilerJSON: Self.realJSON))
        #expect(health.condition == "Good")
        #expect(health.maximumCapacityPercent == 95)
        #expect(health.cycleCount == 128)
    }

    /// A desktop Mac has no battery block at all. That is `nil`, which is what
    /// hides the sidebar item — not a zeroed BatteryHealth.
    @Test("a machine with no battery yields nil, not an empty reading")
    func noBatteryYieldsNil() throws {
        let none = Data("""
        {"SPPowerDataType":[{"_name":"sppower_ac_info"}]}
        """.utf8)
        #expect(try BatteryHealthParser.parse(profilerJSON: none) == nil)
    }

    /// The capacity arrives as the string "95%", not a number.
    @Test("a capacity that cannot be parsed is nil, never zero")
    func unparseableCapacityIsNil() throws {
        let odd = Data("""
        {"SPPowerDataType":[{"_name":"spbattery_information",
          "sppower_battery_health_info":{"sppower_battery_cycle_count":128,
            "sppower_battery_health":"Good",
            "sppower_battery_health_maximum_capacity":"unknown"}}]}
        """.utf8)
        let health = try #require(try BatteryHealthParser.parse(profilerJSON: odd))
        #expect(health.maximumCapacityPercent == nil)
        #expect(health.cycleCount == 128)
    }
}
