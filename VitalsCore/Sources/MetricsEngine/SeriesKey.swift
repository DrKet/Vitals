import Foundation

/// Identifies one stream of measurements.
public enum SeriesKey: String, Sendable, Hashable, CaseIterable {
    case cpu
    case memory
    case gpu
    case storage
    case network
    case processes
    case diskIO
    case sensors
    case battery
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

/// When a reading stops being current enough to headline as live.
///
/// Keyed off a series' real sampling *interval*, not its `SamplingCadence`:
/// `MetricsEngine.intervalOverride` can collapse every cadence to one interval,
/// so the cadence's nominal figure is not always what a series is sampled at.
/// Ask the engine what it is actually doing — see
/// `MetricsEngine.samplingInterval(for:)`.
public enum LiveStaleness: Sendable {

    /// Sampling intervals a reading may miss before it is no longer current.
    /// Two tolerates a single dropped tick.
    public static let intervalMultiple = 2

    /// Floor under the threshold, however fast a series samples.
    ///
    /// `MetricsStore` is `@MainActor`, and a busy main actor delays ticks: this
    /// project measured concurrent window renders starving a main-actor poll
    /// loop for over two seconds. At the 1-second fast cadence a bare 2×
    /// multiple would blank the largest number on screen during a window resize
    /// and restore it a moment later. The floor buys enough slack that only a
    /// genuine stop — navigating away, sampling ending — expires a reading,
    /// while still being far short of leaving an hour-old value looking live.
    public static let floor: Duration = .seconds(10)

    /// Age past which a sample taken every `interval` is no longer current.
    public static func threshold(forInterval interval: Duration) -> Duration {
        max(interval * intervalMultiple, floor)
    }

    /// Whether a sample taken at `sampleTimestamp` (system uptime) is still
    /// current at `now`. Strictly older than the threshold is stale.
    public static func isLive(
        sampleTimestamp: TimeInterval,
        now: TimeInterval,
        interval: Duration
    ) -> Bool {
        now - sampleTimestamp <= threshold(forInterval: interval).timeInterval
    }
}

extension Duration {
    /// Seconds as `TimeInterval`, for comparing against system-uptime stamps.
    public var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
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
