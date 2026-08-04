import Foundation
import IOKit
import IOKit.ps

public enum BatterySampler {

    /// Reads live electrical values from `AppleSmartBattery` via the
    /// IORegistry.
    ///
    /// Returns `nil` — never a zeroed sample — when the service is absent
    /// (desktop Macs have no battery) or any required key is missing. Task 4
    /// relies on exactly that `nil` to hide the sidebar item on hardware
    /// without a battery, so a zeroed placeholder here would be a lie two
    /// layers up.
    public static func read() -> BatterySample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // Amperage is read as UInt64 and reinterpreted through
        // BatterySample.milliamps(fromRegistryValue:) — see that function's
        // doc comment for why a plain Int read is wrong on battery power.
        guard let chargePercent = (dictionary["CurrentCapacity"] as? NSNumber)?.intValue,
              let millivolts = (dictionary["Voltage"] as? NSNumber)?.intValue,
              let rawAmperage = (dictionary["Amperage"] as? NSNumber)?.uint64Value,
              let rawTimeRemaining = (dictionary["TimeRemaining"] as? NSNumber)?.intValue,
              let isCharging = (dictionary["IsCharging"] as? NSNumber)?.boolValue,
              let isExternalPowerConnected = (dictionary["ExternalConnected"] as? NSNumber)?.boolValue,
              let rawTemperature = (dictionary["Temperature"] as? NSNumber)?.intValue
        else { return nil }

        let milliamps = BatterySample.milliamps(fromRegistryValue: rawAmperage)

        return BatterySample(
            watts: BatterySample.watts(millivolts: millivolts, milliamps: milliamps),
            chargePercent: chargePercent,
            isCharging: isCharging,
            isExternalPowerConnected: isExternalPowerConnected,
            minutesRemaining: BatterySample.minutesRemaining(fromRegistryValue: rawTimeRemaining),
            volts: Double(millivolts) / 1000,
            celsius: BatterySample.celsius(fromRegistryValue: rawTemperature),
            warningLevel: warningLevel(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func warningLevel() -> BatteryWarningLevel {
        switch IOPSGetBatteryWarningLevel() {
        case kIOPSLowBatteryWarningEarly: .early
        case kIOPSLowBatteryWarningFinal: .final
        default: .none
        }
    }
}
