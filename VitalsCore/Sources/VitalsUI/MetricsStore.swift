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

    public private(set) var sensors: SensorSample?
    public private(set) var sensorHistory: [Timestamped<SensorSample>] = []

    /// Latest only — volume capacity changes over minutes, not seconds, so a
    /// 600-sample ring of near-identical readings would be pure waste.
    public private(set) var volumes: [Volume]?

    public private(set) var network: [String: NetworkThroughput]?
    public private(set) var networkHistory: [Timestamped<[String: NetworkThroughput]>] = []

    public private(set) var diskIO: [String: DiskThroughput]?
    public private(set) var diskIOHistory: [Timestamped<[String: DiskThroughput]>] = []

    /// Latest process listing. Deliberately no history: a 600-sample ring of
    /// ~600 processes would be 360,000 snapshots for a table that only ever
    /// shows the present. Same reasoning as `volumes`.
    public private(set) var processes: ProcessSeriesSample?

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

    /// Per-series watch that nils the live field once the sample ages past
    /// `SamplingCadence.liveStalenessThreshold`. History is left alone so
    /// charts keep gap-breaking across the quiet stretch.
    private var stalenessWatches: [SeriesKey: Task<Void, Never>] = [:]

    /// Real sampling interval per series, read from the engine when
    /// `stream(_:)` subscribed rather than re-derived from the key.
    private var samplingIntervals: [SeriesKey: Duration] = [:]

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
        // Read the real interval once, here, where we are already async. The
        // staleness gate needs it on every tick and `apply` is synchronous, so
        // caching it is what lets the gate use the engine's answer instead of
        // a second copy of the cadence table.
        if let interval = await engine.samplingInterval(for: key) {
            samplingIntervals[key] = interval
        }
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
            armStalenessWatch(for: key)
        case .memory:
            guard let sample = value.value as? MemorySample else { return }
            memory = sample
            append(Timestamped(timestamp: value.timestamp, sample: sample), to: &memoryHistory)
            armStalenessWatch(for: key)
        case .gpu:
            guard let samples = value.value as? [GPUSample] else { return }
            gpu = samples
            append(Timestamped(timestamp: value.timestamp, sample: samples), to: &gpuHistory)
            armStalenessWatch(for: key)
        case .storage:
            guard let latest = value.value as? [Volume] else { return }
            volumes = latest
            armStalenessWatch(for: key)
        case .network:
            guard let throughput = value.value as? [String: NetworkThroughput] else { return }
            network = throughput
            append(Timestamped(timestamp: value.timestamp, sample: throughput), to: &networkHistory)
            armStalenessWatch(for: key)
        case .processes:
            guard let sample = value.value as? ProcessSeriesSample else { return }
            processes = sample
            armStalenessWatch(for: key)
        case .diskIO:
            guard let throughput = value.value as? [String: DiskThroughput] else { return }
            diskIO = throughput
            append(Timestamped(timestamp: value.timestamp, sample: throughput), to: &diskIOHistory)
            armStalenessWatch(for: key)
        case .sensors:
            guard let sample = value.value as? SensorSample else { return }
            sensors = sample
            append(Timestamped(timestamp: value.timestamp, sample: sample), to: &sensorHistory)
            armStalenessWatch(for: key)
        }
    }

    /// The interval a series is really sampled at, as reported by the engine
    /// when `stream(_:)` subscribed. Falls back to the fast cadence only for a
    /// series that was never subscribed through this store.
    ///
    /// Deliberately not re-derived from the key: the cadence lives in
    /// `StandardSamplers.registerAll` and `MetricsEngine.intervalOverride` can
    /// collapse it, so any copy here would drift from what sampling actually
    /// does — silently, since a wrong threshold only shows up as readings
    /// expiring too early or too late.
    private func samplingInterval(for key: SeriesKey) -> Duration {
        samplingIntervals[key] ?? SamplingCadence.fast.interval
    }

    /// Whether a series' live field expires once it goes stale.
    ///
    /// Volume capacity does not. The store keeps no history for it precisely
    /// because it changes over minutes rather than seconds, and a free-space
    /// figure a few seconds old is not stale in any sense a reader would care
    /// about — expiring it would blank the Storage page's volume bars and
    /// capacity rows on any pause. Every other live field is a rate or a
    /// utilisation, where seconds old genuinely is out of date.
    private func expiresWhenStale(_ key: SeriesKey) -> Bool {
        switch key {
        case .storage: false
        case .cpu, .memory, .gpu, .network, .diskIO, .processes, .sensors: true
        }
    }

    /// After each accepted tick, schedule a freshness check one threshold out.
    /// A later tick cancels and re-arms, so an actively sampled series never
    /// flickers to absent on one missed beat; once sampling stops, live fields
    /// go `nil` and primaries fall through to the em-dash path.
    ///
    /// The check sweeps every series rather than just `key`. That is deliberate
    /// belt-and-braces: a series that has already stopped ticking has nothing
    /// left to re-arm its own watch, so it relies on some other series' watch
    /// firing. With nothing ticking at all, the last watch to fire clears
    /// everything that has gone stale.
    private func armStalenessWatch(for key: SeriesKey) {
        guard expiresWhenStale(key) else { return }
        stalenessWatches[key]?.cancel()
        let threshold = LiveStaleness.threshold(forInterval: samplingInterval(for: key))
        stalenessWatches[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled, let self else { return }
            self.expireStaleLiveSamples()
        }
    }

    /// Nils any live field whose last sample has aged past its series'
    /// threshold at `now`. History is left alone so charts keep gap-breaking.
    ///
    /// Called from the per-series staleness watch; `now` is injectable so tests
    /// can advance past the threshold without waiting on wall clock (which
    /// races under a parallel suite on a busy MainActor).
    func expireStaleLiveSamples(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for key in SeriesKey.allCases where expiresWhenStale(key) {
            guard let stampedAt = lastAppliedTimestamp[key] else { continue }
            let live = LiveStaleness.isLive(
                sampleTimestamp: stampedAt,
                now: now,
                interval: samplingInterval(for: key)
            )
            guard !live else { continue }
            clearLiveSample(for: key)
        }
    }

    /// Clears one series' live field. Which series are exempt is decided in
    /// `expiresWhenStale` and nowhere else — a second guard here would mean
    /// the exemption could be removed there without any behaviour changing,
    /// which is precisely what made the first version of `volumesNeverExpire`
    /// pass against deliberately broken code.
    private func clearLiveSample(for key: SeriesKey) {
        switch key {
        case .cpu: cpu = nil
        case .memory: memory = nil
        case .gpu: gpu = nil
        case .storage: volumes = nil
        case .network: network = nil
        case .diskIO: diskIO = nil
        case .processes: processes = nil
        case .sensors: sensors = nil
        }
    }

    /// Whether `timestamp` starts a new run rather than continuing the last one.
    ///
    /// Sampling is subscription-driven, so leaving a page stops it and history
    /// keeps whatever was collected before. The chart already refuses to draw
    /// a line across that hole. What it cannot fix is the geometry:
    /// `ChartGeometry.sampleX` spaces samples by INDEX, and a gap occupies no
    /// indices because absent readings are never appended — so ten minutes
    /// away renders exactly one sample-step wide, indistinguishable from one
    /// tick. The two runs end up drawn shoulder to shoulder, which asserts an
    /// adjacency that never happened. That is the same class of error the
    /// gap-break exists to prevent, displaced from the stroke into the axis.
    ///
    /// So a resumed run drops what came before it. Deliberately reuses
    /// `ChartGeometry.gapThreshold` rather than a second rule of its own: if
    /// the store and the renderer disagreed about where a gap is, the store
    /// could discard a run the renderer would have kept whole, or keep one it
    /// was about to split.
    ///
    /// `nil` from `gapThreshold` means fewer than two samples — not enough
    /// information to judge, and guessing would throw away real readings.
    static func beginsNewRun(after timestamps: [TimeInterval], at timestamp: TimeInterval) -> Bool {
        guard let threshold = ChartGeometry.gapThreshold(for: timestamps),
              let last = timestamps.last else { return false }
        return timestamp - last > threshold
    }

    private func append<Value>(_ sample: Timestamped<Value>, to history: inout [Timestamped<Value>]) {
        if Self.beginsNewRun(after: history.map(\.timestamp), at: sample.timestamp) {
            history.removeAll()
        }

        // `max(historyLimit, 1)` so a nonsensical limit trims to one sample
        // rather than trapping in `removeFirst` with a count past the end.
        let limit = max(historyLimit, 1)
        history.append(sample)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}
