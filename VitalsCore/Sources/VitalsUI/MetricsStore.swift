import MetricsEngine
import Observation
import SystemMetrics

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
    public private(set) var cpuHistory: [CPULoadSample] = []

    public private(set) var memory: MemorySample?
    public private(set) var memoryHistory: [MemorySample] = []

    /// Uptime and load average. Cheap and slow-moving, so it is read on demand
    /// rather than sampled on a schedule.
    public var systemLoad: SystemLoad { SystemLoad.current() }

    /// Static hardware description. `nil` only in tests; the app always has one.
    public let profile: HardwareProfile?

    private let engine: MetricsEngine
    private let historyLimit: Int

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
        // A payload of an unexpected type is dropped rather than crashing or
        // substituted with a zero — an unreadable series shows as absent.
        switch key {
        case .cpu:
            guard let sample = value.value as? CPULoadSample else { return }
            cpu = sample
            append(sample, to: &cpuHistory)
        case .memory:
            guard let sample = value.value as? MemorySample else { return }
            memory = sample
            append(sample, to: &memoryHistory)
        case .gpu, .storage, .network, .processes:
            // Handled by later plans. Ignored rather than crashed on, so a page
            // that subscribes early does not fault.
            return
        }
    }

    private func append<Sample>(_ sample: Sample, to history: inout [Sample]) {
        history.append(sample)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
