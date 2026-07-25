import Foundation

/// Identifies one stream of measurements.
public enum SeriesKey: String, Sendable, Hashable, CaseIterable {
    case cpu
    case memory
    case gpu
    case storage
    case network
    case processes
}

/// How often a series is refreshed. Cheap counters run fast; expensive
/// enumerations run slow; hardware inventory barely changes at all.
public enum SamplingCadence: Sendable, Equatable {
    case fast
    case slow
    case `static`

    public var interval: Duration {
        switch self {
        case .fast: .seconds(1)
        case .slow: .seconds(5)
        case .static: .seconds(60)
        }
    }
}

/// One timestamped measurement. The engine is generic over payload type, so
/// values are boxed as `Any` at the boundary and cast by the consumer.
public struct MetricValue: @unchecked Sendable {
    public let timestamp: TimeInterval
    public let value: Any

    public init<Value: Sendable>(timestamp: TimeInterval, value: Value) {
        self.timestamp = timestamp
        self.value = value
    }

    /// Construction path for values already boxed as `Any` by `AnySampler`,
    /// whose own initializer constrained the original payload to `Sendable`
    /// before erasure. By the time that value reaches here its static type
    /// is `Any`, so the generic, checked initializer above can't accept it --
    /// this internal entry point exists so the engine can carry it forward
    /// without re-deriving a static Sendable proof the type system can no
    /// longer express. Not public: nothing outside this module can use it to
    /// smuggle an unverified value.
    init(timestamp: TimeInterval, uncheckedValue: Any) {
        self.timestamp = timestamp
        self.value = uncheckedValue
    }
}

/// Type-erased sampler closure, so heterogeneous samplers can share one
/// registry.
public struct AnySampler: Sendable {
    private let block: @Sendable () throws -> Any

    public init<Value: Sendable>(_ block: @escaping @Sendable () throws -> Value) {
        self.block = { try block() }
    }

    public func sample() throws -> Any {
        try block()
    }
}
