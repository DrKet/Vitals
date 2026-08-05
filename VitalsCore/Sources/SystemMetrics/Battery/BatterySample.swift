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
    /// `nil` when the gas gauge has not settled — see `minutesRemaining(from:)`.
    public let minutesRemaining: Int?
    public let volts: Double
    public let celsius: Double
    public let warningLevel: BatteryWarningLevel
    public let isLowPowerMode: Bool

    public init(
        watts: Double, chargePercent: Int, isCharging: Bool,
        isExternalPowerConnected: Bool, minutesRemaining: Int?,
        volts: Double, celsius: Double,
        warningLevel: BatteryWarningLevel, isLowPowerMode: Bool
    ) {
        self.watts = watts
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isExternalPowerConnected = isExternalPowerConnected
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

    /// The gas gauge reports `65535` for "not yet known". Passing that through
    /// would claim about 45 days of runtime.
    ///
    /// Zero is deliberately NOT treated as a sentinel: an empty or fully
    /// charged battery genuinely has zero minutes left in its current
    /// direction.
    public static func minutesRemaining(fromRegistryValue raw: Int) -> Int? {
        raw == 65535 ? nil : raw
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
