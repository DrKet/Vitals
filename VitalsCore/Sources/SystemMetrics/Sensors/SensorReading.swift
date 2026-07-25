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

    public init(name: String, kind: Kind, value: Double) {
        self.name = name
        self.kind = kind
        self.value = value
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
