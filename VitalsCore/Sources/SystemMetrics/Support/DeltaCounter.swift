import Foundation

/// The change in a monotonic counter over a measured interval.
public struct Delta<Value: FixedWidthInteger & Sendable>: Sendable, Equatable {
    public let amount: Value
    public let interval: TimeInterval

    /// - Precondition: `interval` must be positive. A zero or negative interval
    ///   would make `perSecond` produce `Infinity` or `NaN` — a fabricated-looking
    ///   number — so the invalid state is rejected here rather than allowed to
    ///   propagate into a chart. `DeltaCounter` never constructs a `Delta` with a
    ///   non-positive interval; it returns `nil` instead.
    public init(amount: Value, interval: TimeInterval) {
        precondition(interval > 0, "Delta.interval must be positive; got \(interval)")
        self.amount = amount
        self.interval = interval
    }

    /// Rate per second. `interval` is guaranteed positive by the initializer.
    public var perSecond: Double {
        Double(amount) / interval
    }
}

/// Converts successive readings of a monotonic counter into rates.
///
/// Returns `nil` — rather than a misleading value — whenever a rate cannot be
/// computed honestly: on the first sample, on counter wraparound or reset, and
/// on a non-advancing timestamp.
public struct DeltaCounter<Value: FixedWidthInteger & Sendable>: Sendable {
    private var previous: (value: Value, timestamp: TimeInterval)?

    public init() {}

    public mutating func update(_ value: Value, at timestamp: TimeInterval) -> Delta<Value>? {
        defer { previous = (value, timestamp) }
        guard let previous else { return nil }
        guard timestamp > previous.timestamp else { return nil }
        guard value >= previous.value else { return nil }
        return Delta(amount: value - previous.value, interval: timestamp - previous.timestamp)
    }

    public mutating func reset() {
        previous = nil
    }
}
