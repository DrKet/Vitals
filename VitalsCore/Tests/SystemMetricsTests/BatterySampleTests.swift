import Foundation
import Testing
@testable import SystemMetrics

@Suite("Battery sample")
struct BatterySampleTests {

    /// Both directions measured from a real Mac14,9: 4090 while charging,
    /// 18446744073709550565 while discharging. The second is -1051 in UInt64
    /// wraparound, and it only ever appears on battery power — which is why a
    /// naive read looks correct on a plugged-in machine.
    @Test("amperage is reinterpreted from unsigned, in both directions")
    func amperageReinterpretsSign() {
        #expect(BatterySample.milliamps(fromRegistryValue: 4090) == 4090)
        #expect(BatterySample.milliamps(fromRegistryValue: 18_446_744_073_709_550_565) == -1051)
    }

    /// 65535 is the gas gauge's "I don't know yet" sentinel. Rendering it
    /// would claim 45 days of runtime.
    @Test("an unsettled time estimate is nil, never 65535")
    func unsettledTimeEstimateIsNil() {
        #expect(BatterySample.minutesRemaining(fromRegistryValue: 65535) == nil)
        #expect(BatterySample.minutesRemaining(fromRegistryValue: 82) == 82)
        // Zero is a real reading when a battery is empty or full, not a sentinel.
        #expect(BatterySample.minutesRemaining(fromRegistryValue: 0) == 0)
    }

    /// Magnitude, never signed: the chart plots how much power is moving and
    /// the stats say which way. Measured discharging: 11.081 V x 1.051 A.
    @Test("power is the magnitude of volts times amps")
    func powerIsMagnitude() {
        #expect(abs(BatterySample.watts(millivolts: 11081, milliamps: -1051) - 11.646) < 0.01)
        #expect(abs(BatterySample.watts(millivolts: 11081, milliamps: 4090) - 45.32) < 0.01)
        // Charging and discharging at the same rate must plot identically.
        #expect(abs(BatterySample.watts(millivolts: 11081, milliamps: -4090)
                    - BatterySample.watts(millivolts: 11081, milliamps: 4090)) < 1e-9)
    }

    /// Registry temperature is in hundredths of a degree: 3014 is 30.14 degC.
    @Test("temperature converts from hundredths of a degree")
    func temperatureConverts() {
        #expect(abs(BatterySample.celsius(fromRegistryValue: 3014) - 30.14) < 1e-9)
    }
}
