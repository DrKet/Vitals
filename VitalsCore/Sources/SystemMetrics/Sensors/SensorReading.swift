import Foundation

/// A single hardware sensor value.
///
/// The concrete provider that reads temperatures, fans, and power requires
/// `IOHIDEventSystemClient`, a private framework. That implementation is a
/// dedicated task in a later plan, developed empirically against real
/// hardware. This file exists so consumers can be written against a stable
/// interface in the meantime.
public struct SensorReading: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case temperatureCelsius
        case fanRPM
        case powerWatts
    }

    public let name: String
    public let kind: Kind
    public let value: Double

    /// How many sensors reported this name.
    ///
    /// The spike (docs/superpowers/spikes/2026-08-02-sensors-spike.md) found
    /// no unique identifier for a sensor: `RegistryID` and `UniqueID` are
    /// absent, and `Product`+`LocationID` still collides on 28 of the 64
    /// temperature sensors, because `LocationID` is only a FourCC of the name.
    /// So a reading names a *group*, and this is how many sensors are in it —
    /// a measured fact, and the honest answer to "which sensor is this", which
    /// has no better answer.
    public let sensorCount: Int

    public init(name: String, kind: Kind, value: Double, sensorCount: Int) {
        self.name = name
        self.kind = kind
        self.value = value
        self.sensorCount = sensorCount
    }
}

/// One tick of sensor data.
///
/// Separate from `SensorReading` because `thermalState` is a property of the
/// machine, not of any one sensor.
public struct SensorSample: Sendable, Equatable {
    public let readings: [SensorReading]

    /// Apple's own thermal severity signal, and the only severity source in
    /// this design. Every alternative would require choosing temperature
    /// thresholds, and the spike could not establish this machine's limits —
    /// so a threshold we picked would assert something about the hardware that
    /// was never measured.
    public let thermalState: ProcessInfo.ThermalState

    public init(readings: [SensorReading], thermalState: ProcessInfo.ThermalState) {
        self.readings = readings
        self.thermalState = thermalState
    }
}

public protocol SensorProviding: Sendable {
    var availability: MetricAvailability { get }
    func readings() -> [SensorReading]
}

/// The provider in use until the IOHID implementation lands. It reports
/// unavailability honestly rather than returning fabricated readings.
public struct UnavailableSensorProvider: SensorProviding {
    public init() {}

    public var availability: MetricAvailability {
        .unavailable(reason: "Sensor access is not yet implemented")
    }

    public func readings() -> [SensorReading] { [] }
}
