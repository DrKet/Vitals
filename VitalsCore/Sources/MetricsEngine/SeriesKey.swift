import Foundation
import SystemMetrics

/// Identifies one stream of measurements.
public enum SeriesKey: String, Sendable, Hashable, CaseIterable {
    case cpu
    case memory
    case gpu
    case storage
    case network
    case processes
    case diskIO
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

/// Read and write throughput for one block device, in bytes per second.
public struct DiskThroughput: Sendable, Equatable {
    public let bytesReadPerSecond: Double
    public let bytesWrittenPerSecond: Double

    public init(bytesReadPerSecond: Double, bytesWrittenPerSecond: Double) {
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
    }
}

/// Turns cumulative per-device byte counters into throughput.
///
/// One `DeltaCounter` per device per direction, mirroring
/// `NetworkThroughputTracker`: devices come and go (external drives, disk
/// images), and a shared counter would let one device's disappearance corrupt
/// another's rate.
public struct DiskThroughputTracker: Sendable {
    private var read: [String: DeltaCounter<UInt64>] = [:]
    private var written: [String: DeltaCounter<UInt64>] = [:]

    public init() {}

    public mutating func update(
        _ counters: [String: StorageIOCounters],
        at timestamp: TimeInterval
    ) -> [String: DiskThroughput] {
        var result: [String: DiskThroughput] = [:]

        for (device, counter) in counters {
            var readCounter = read[device] ?? DeltaCounter<UInt64>()
            var writeCounter = written[device] ?? DeltaCounter<UInt64>()

            let readDelta = readCounter.update(counter.bytesRead, at: timestamp)
            let writeDelta = writeCounter.update(counter.bytesWritten, at: timestamp)

            read[device] = readCounter
            written[device] = writeCounter

            // Both directions must be valid; a reset on either invalidates the
            // interval for this device rather than reporting half a reading.
            if let readDelta, let writeDelta {
                result[device] = DiskThroughput(
                    bytesReadPerSecond: readDelta.perSecond,
                    bytesWrittenPerSecond: writeDelta.perSecond
                )
            }
        }

        // Forget departed devices so a reappearance starts fresh instead of
        // producing a huge delta against a stale reading.
        read = read.filter { counters.keys.contains($0.key) }
        written = written.filter { counters.keys.contains($0.key) }

        return result
    }
}
