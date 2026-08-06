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

    /// On battery, the countdown is time to empty. Measured together on this
    /// machine: IOPS said 164 minutes and `pmset` said "2:44 remaining" at the
    /// same moment, which is the same number — IOPS is the source every other
    /// macOS surface reads.
    @Test("on battery, the estimate is time to empty")
    func onBatteryReadsTimeToEmpty() {
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: 164, timeToFullCharge: 0,
            isCharging: false, isExternalPowerConnected: false
        ) == 164)
    }

    /// Charging counts up to full instead, and the two keys are both present
    /// at once — measured while discharging, `Time to Full Charge` still read
    /// 0 rather than being absent. Reading the wrong one would therefore not
    /// produce an obvious nil; it would produce a confident, wrong number.
    @Test("charging, the estimate is time to full — not the stale time-to-empty")
    func chargingReadsTimeToFull() {
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: 999, timeToFullCharge: 42,
            isCharging: true, isExternalPowerConnected: true
        ) == 42)
    }

    /// Plugged in and already full: nothing is counting in either direction,
    /// so neither key means anything. An em dash is the honest answer, and it
    /// is the reason this takes both flags rather than `isCharging` alone.
    @Test("charged on AC has no time estimate at all, in either key")
    func chargedOnACHasNoEstimate() {
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: 600, timeToFullCharge: 0,
            isCharging: false, isExternalPowerConnected: true
        ) == nil)
    }

    /// -1 is IOPS's "still calculating", and it is measured, not assumed: in
    /// the first seconds after the adapter went in, `Time to Full Charge`
    /// read -1 while `pmset` said "(no estimate)" — and the IORegistry's
    /// `TimeRemaining` claimed a confident 74 minutes at that same moment.
    /// Rendering the registry's number there would state an estimate macOS
    /// itself declines to make.
    @Test("a negative estimate is unknown, never rendered as a duration")
    func negativeEstimateIsNil() {
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: 0, timeToFullCharge: -1,
            isCharging: true, isExternalPowerConnected: true
        ) == nil)
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: -1, timeToFullCharge: 0,
            isCharging: false, isExternalPowerConnected: false
        ) == nil)
    }

    /// An absent key is unknown too — distinct from a present zero.
    @Test("an absent key is unknown, and is not confused with zero")
    func absentKeyIsNil() {
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: nil, timeToFullCharge: nil,
            isCharging: false, isExternalPowerConnected: false
        ) == nil)
        // Zero is a real reading on a battery about to die, not a sentinel.
        #expect(BatterySample.minutesRemaining(
            timeToEmpty: 0, timeToFullCharge: nil,
            isCharging: false, isExternalPowerConnected: false
        ) == 0)
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
