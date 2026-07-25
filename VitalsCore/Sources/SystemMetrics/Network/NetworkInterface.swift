import Foundation

/// Cumulative counters for one network interface.
public struct InterfaceCounters: Sendable, Equatable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let packetsIn: UInt64
    public let packetsOut: UInt64
    public let errorsIn: UInt64
    public let errorsOut: UInt64

    public init(
        name: String, bytesIn: UInt64, bytesOut: UInt64,
        packetsIn: UInt64, packetsOut: UInt64,
        errorsIn: UInt64, errorsOut: UInt64
    ) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
    }
}

public struct NetworkThroughput: Sendable, Equatable {
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
}

/// Converts successive interface counter readings into throughput, keeping one
/// `DeltaCounter` per interface so that interfaces appearing or disappearing
/// never corrupt another interface's rate.
public struct NetworkThroughputTracker: Sendable {
    private var inbound: [String: DeltaCounter<UInt64>] = [:]
    private var outbound: [String: DeltaCounter<UInt64>] = [:]

    public init() {}

    public mutating func update(
        _ interfaces: [InterfaceCounters],
        at timestamp: TimeInterval
    ) -> [String: NetworkThroughput] {
        var result: [String: NetworkThroughput] = [:]
        var seen: Set<String> = []

        for interface in interfaces {
            seen.insert(interface.name)

            var inCounter = inbound[interface.name] ?? DeltaCounter<UInt64>()
            var outCounter = outbound[interface.name] ?? DeltaCounter<UInt64>()

            let inDelta = inCounter.update(interface.bytesIn, at: timestamp)
            let outDelta = outCounter.update(interface.bytesOut, at: timestamp)

            inbound[interface.name] = inCounter
            outbound[interface.name] = outCounter

            // Both directions must be valid; a reset on either invalidates the
            // interval for this interface.
            if let inDelta, let outDelta {
                result[interface.name] = NetworkThroughput(
                    bytesInPerSecond: inDelta.perSecond,
                    bytesOutPerSecond: outDelta.perSecond
                )
            }
        }

        // Forget interfaces that have gone away so a later reappearance starts
        // fresh instead of producing a huge spurious delta.
        inbound = inbound.filter { seen.contains($0.key) }
        outbound = outbound.filter { seen.contains($0.key) }

        return result
    }
}
