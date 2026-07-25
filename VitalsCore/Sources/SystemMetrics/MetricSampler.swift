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

/// One source of one kind of measurement.
///
/// Implementations must be independently failable: throwing here degrades a
/// single series to unavailable and must never stop the engine or affect
/// another sampler.
public protocol MetricSampler: Sendable {
    associatedtype Sample: Sendable

    var availability: MetricAvailability { get }
    func sample() throws -> Sample
}
