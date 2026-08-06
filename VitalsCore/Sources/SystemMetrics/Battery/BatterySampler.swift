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
              let isCharging = (dictionary["IsCharging"] as? NSNumber)?.boolValue,
              let isExternalPowerConnected = (dictionary["ExternalConnected"] as? NSNumber)?.boolValue,
              let rawTemperature = (dictionary["Temperature"] as? NSNumber)?.intValue
        else { return nil }

        let milliamps = BatterySample.milliamps(fromRegistryValue: rawAmperage)
        let estimates = timeEstimates()

        return BatterySample(
            watts: BatterySample.watts(millivolts: millivolts, milliamps: milliamps),
            chargePercent: chargePercent,
            isCharging: isCharging,
            isExternalPowerConnected: isExternalPowerConnected,
            minutesRemaining: BatterySample.minutesRemaining(
                timeToEmpty: estimates.toEmpty,
                timeToFullCharge: estimates.toFull,
                isCharging: isCharging,
                isExternalPowerConnected: isExternalPowerConnected
            ),
            volts: Double(millivolts) / 1000,
            celsius: BatterySample.celsius(fromRegistryValue: rawTemperature),
            warningLevel: warningLevel(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// The two time estimates from the IOPS power-source dictionary — the
    /// same source `pmset` and the menu bar read. Either is `nil` when the
    /// key is absent; `BatterySample.minutesRemaining` decides which one
    /// applies and what a negative means.
    ///
    /// Read from IOPS rather than from the `AppleSmartBattery` dictionary
    /// this function's caller already holds: see that method's doc comment
    /// for the measurements behind choosing the smoothed estimate over the
    /// raw gas gauge.
    private static func timeEstimates() -> (toEmpty: Int?, toFull: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }

        // The internal battery is the only source with these keys on a Mac;
        // taking the first that describes one avoids inventing a rule for
        // multi-source machines that has never been observed.
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let toEmpty = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
            let toFull = (description[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue
            if toEmpty != nil || toFull != nil { return (toEmpty, toFull) }
        }
        return (nil, nil)
    }

    private static func warningLevel() -> BatteryWarningLevel {
        switch IOPSGetBatteryWarningLevel() {
        case kIOPSLowBatteryWarningEarly: .early
        case kIOPSLowBatteryWarningFinal: .final
        default: .none
        }
    }
}
