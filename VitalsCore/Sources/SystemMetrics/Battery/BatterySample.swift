import Foundation

public enum BatteryWarningLevel: Sendable, Equatable {
    case none, early, final
}

public struct BatterySample: Sendable, Equatable {
    /// Magnitude of power moving in or out, in watts.
    ///
    /// Never signed. Current flows out when discharging and in when charging;
    /// plotting -11.6 W and +45.3 W on one axis would conflate two different
    /// physical events, and `.absolute` chart bounds are zero-based so a
    /// negative would clamp to zero and vanish entirely.
    public let watts: Double
    public let chargePercent: Int
    public let isCharging: Bool
    public let isExternalPowerConnected: Bool
    /// Whether the battery has actually reached full.
    ///
    /// Distinct from `!isCharging` while on AC: macOS holds a battery part-
    /// charged and not charging for long stretches under optimised battery
    /// charging, and reports "AC attached; not charging" for it. Without this
    /// flag those two states are indistinguishable and the page calls both
    /// "Charged".
    public let isFullyCharged: Bool
    /// Minutes to empty, or to full while charging. `nil` when the estimate
    /// is still being calculated, and also when the machine is plugged in and
    /// already charged — nothing is counting in either direction then. See
    /// `minutesRemaining(timeToEmpty:timeToFullCharge:isCharging:isExternalPowerConnected:)`.
    public let minutesRemaining: Int?
    public let volts: Double
    public let celsius: Double
    public let warningLevel: BatteryWarningLevel
    public let isLowPowerMode: Bool

    public init(
        watts: Double, chargePercent: Int, isCharging: Bool,
        isExternalPowerConnected: Bool, isFullyCharged: Bool, minutesRemaining: Int?,
        volts: Double, celsius: Double,
        warningLevel: BatteryWarningLevel, isLowPowerMode: Bool
    ) {
        self.watts = watts
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isExternalPowerConnected = isExternalPowerConnected
        self.isFullyCharged = isFullyCharged
        self.minutesRemaining = minutesRemaining
        self.volts = volts
        self.celsius = celsius
        self.warningLevel = warningLevel
        self.isLowPowerMode = isLowPowerMode
    }

    /// Reinterprets `AppleSmartBattery`'s `Amperage`, which is a signed value
    /// delivered unsigned.
    ///
    /// Measured on a Mac14,9: `4090` while charging, `18446744073709550565`
    /// while discharging — the latter being -1051 in `UInt64` wraparound. The
    /// defect therefore only manifests on battery power, so an implementation
    /// that skips this looks entirely correct on a plugged-in machine.
    public static func milliamps(fromRegistryValue raw: UInt64) -> Int64 {
        Int64(bitPattern: raw)
    }

    /// Minutes left in whichever direction the battery is actually moving,
    /// from the IOPS power-source dictionary.
    ///
    /// IOPS rather than the IORegistry's `TimeRemaining` deliberately. Both
    /// are honest readings, but they are different estimators and they
    /// disagree substantially and in both directions — measured on this
    /// machine within one session: registry 271 against IOPS 505, then later
    /// registry 294 against IOPS 164. IOPS is what `pmset`, the menu bar and
    /// Settings all read (IOPS 164 and `pmset` "2:44" were the same reading
    /// at the same moment), so it is the one that does not contradict the
    /// rest of the system on the user's own screen.
    ///
    /// Takes both flags rather than `isCharging` alone because there are
    /// three states, not two. Plugged in and full is neither counting down
    /// nor counting up, and both keys are always present regardless — while
    /// discharging, `Time to Full Charge` still reads `0` rather than being
    /// absent — so choosing on `isCharging` alone would surface a confident
    /// wrong number rather than an obvious nil.
    public static func minutesRemaining(
        timeToEmpty: Int?, timeToFullCharge: Int?,
        isCharging: Bool, isExternalPowerConnected: Bool
    ) -> Int? {
        let raw: Int?
        if !isExternalPowerConnected {
            raw = timeToEmpty
        } else if isCharging {
            raw = timeToFullCharge
        } else {
            // Charged on AC: neither key describes anything happening.
            return nil
        }

        // IOPS documents -1 for "still calculating". Every negative reads as
        // unknown, which needs no assumption about -1 being the only
        // sentinel. Zero stays a real reading: a battery minutes from empty
        // genuinely has zero minutes left.
        guard let raw, raw >= 0 else { return nil }
        return raw
    }

    /// Power as a magnitude. Millivolts and milliamps in, watts out.
    public static func watts(millivolts: Int, milliamps: Int64) -> Double {
        abs(Double(millivolts) / 1000 * Double(milliamps) / 1000)
    }

    /// Registry temperature is in hundredths of a degree Celsius.
    public static func celsius(fromRegistryValue raw: Int) -> Double {
        Double(raw) / 100
    }
}
