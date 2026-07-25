import Foundation

/// Whether a metric can be measured on the current hardware and configuration.
/// An unavailable metric always carries a reason so the UI can explain itself
/// rather than showing a blank or a zero.
public enum MetricAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// A `MetricSampler` protocol was specified here originally. It was removed
// rather than shipped: its `associatedtype Sample` made it unusable as an
// existential, so the engine could never hold heterogeneous samplers in one
// collection — which is the only thing such a protocol would have been for.
// The engine erases samplers through `AnySampler` instead, and nothing ever
// conformed to the protocol. Reintroduce an abstraction here when there is a
// second conformer that needs it.
