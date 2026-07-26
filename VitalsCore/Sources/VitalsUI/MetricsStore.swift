import Foundation
import MetricsEngine
import Observation
import SystemMetrics

/// A sample and the moment it was taken.
///
/// The engine stamps every sample; keeping the stamp is what lets a chart mark
/// where sampling stopped instead of drawing straight through the hole.
public struct Timestamped<Sample: Sendable>: Sendable {
    public let timestamp: TimeInterval
    public let sample: Sample

    public init(timestamp: TimeInterval, sample: Sample) {
        self.timestamp = timestamp
        self.sample = sample
    }
}

/// Bridges `MetricsEngine` to SwiftUI.
///
/// The engine publishes `MetricValue`, whose payload is `Any`. Casting that to a
/// concrete sample type happens here, once, rather than in every view. Views
/// observe typed properties and never see the erasure.
///
/// Subscription lifetime is driven by SwiftUI: a page calls `stream(_:)` from
/// `.task {}`, which SwiftUI cancels when the view disappears. That cancellation
/// terminates the engine's `AsyncStream`, which detaches the subscriber, which
/// stops sampling. The engine's subscription-driven design and SwiftUI's view
/// lifecycle line up exactly, so no manual bookkeeping is needed.
@Observable
@MainActor
public final class MetricsStore {

    public private(set) var cpu: CPULoadSample?
    public private(set) var cpuHistory: [Timestamped<CPULoadSample>] = []

    public private(set) var memory: MemorySample?
    public private(set) var memoryHistory: [Timestamped<MemorySample>] = []

    public private(set) var gpu: [GPUSample]?
    public private(set) var gpuHistory: [Timestamped<[GPUSample]>] = []

    /// Latest only — volume capacity changes over minutes, not seconds, so a
    /// 600-sample ring of near-identical readings would be pure waste.
    public private(set) var volumes: [Volume]?

    public private(set) var network: [String: NetworkThroughput]?
    public private(set) var networkHistory: [Timestamped<[String: NetworkThroughput]>] = []

    /// Uptime and load average. Cheap and slow-moving, so it is read on demand
    /// rather than sampled on a schedule.
    public var systemLoad: SystemLoad { SystemLoad.current() }

    /// Static hardware description. `nil` only in tests; the app always has one.
    public let profile: HardwareProfile?

    private let engine: MetricsEngine
    private let historyLimit: Int

    /// Newest sample timestamp already folded into state, per series. Guards
    /// against the same tick being applied twice when two views subscribe to
    /// one series concurrently.
    private var lastAppliedTimestamp: [SeriesKey: TimeInterval] = [:]

    public init(engine: MetricsEngine, profile: HardwareProfile?, historyLimit: Int = 600) {
        self.engine = engine
        self.profile = profile
        self.historyLimit = historyLimit
    }

    /// Subscribes to a series and republishes it as typed state until cancelled.
    ///
    /// Call from `.task {}`. Returns when the task is cancelled or the stream
    /// finishes.
    public func stream(_ key: SeriesKey) async {
        for await value in await engine.subscribe(to: key) {
            apply(value, for: key)
        }
    }

    private func apply(_ value: MetricValue, for key: SeriesKey) {
        // Two views can legitimately subscribe to the same series at once — the
        // Overview grid and a hardware page overlap during a sidebar switch, and
        // both call `stream(_:)`. The engine fans out one sample to every
        // subscriber, so without this each tick would be appended once per
        // subscriber and the chart would show duplicated history. Keying on the
        // sample's own timestamp makes the store idempotent no matter how many
        // streams are open.
        guard value.timestamp > (lastAppliedTimestamp[key] ?? -.greatestFiniteMagnitude) else {
            return
        }
        lastAppliedTimestamp[key] = value.timestamp

        // A payload of an unexpected type is dropped rather than crashing or
        // substituted with a zero — an unreadable series shows as absent.
        switch key {
        case .cpu:
            guard let sample = value.value as? CPULoadSample else { return }
            cpu = sample
            append(Timestamped(timestamp: value.timestamp, sample: sample), to: &cpuHistory)
        case .memory:
            guard let sample = value.value as? MemorySample else { return }
            memory = sample
            append(Timestamped(timestamp: value.timestamp, sample: sample), to: &memoryHistory)
        case .gpu:
            guard let samples = value.value as? [GPUSample] else { return }
            gpu = samples
            append(Timestamped(timestamp: value.timestamp, sample: samples), to: &gpuHistory)
        case .storage:
            guard let latest = value.value as? [Volume] else { return }
            volumes = latest
        case .network:
            guard let throughput = value.value as? [String: NetworkThroughput] else { return }
            network = throughput
            append(Timestamped(timestamp: value.timestamp, sample: throughput), to: &networkHistory)
        case .processes:
            // The Processes pane is M1-B-3. Ignored rather than crashed on, so
            // a page that subscribes early does not fault.
            return
        }
    }

    private func append<Sample>(_ sample: Sample, to history: inout [Sample]) {
        // `max(historyLimit, 1)` so a nonsensical limit trims to one sample
        // rather than trapping in `removeFirst` with a count past the end.
        let limit = max(historyLimit, 1)
        history.append(sample)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}
