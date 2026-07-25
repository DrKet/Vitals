import Foundation

/// Schedules samplers, retains bounded history, and publishes values to
/// subscribers.
///
/// Sampling is subscription-driven: a series with no subscribers is not
/// sampled at all. This is what keeps a desktop showing only CPU widgets from
/// enumerating the process table every second.
public actor MetricsEngine {

    private struct Registration {
        let sampler: AnySampler
        let cadence: SamplingCadence
    }

    private struct Series {
        var registration: Registration
        var history: RingBuffer<MetricValue>
        var continuations: [UUID: AsyncStream<MetricValue>.Continuation] = [:]
        var task: Task<Void, Never>?
    }

    private var series: [SeriesKey: Series] = [:]
    private let historyCapacity: Int
    private let intervalOverride: Duration?

    /// - Parameters:
    ///   - historyCapacity: samples retained per series. 600 is ten minutes at 1 Hz.
    ///   - intervalOverride: collapses every cadence to one interval. Tests only.
    public init(intervalOverride: Duration? = nil, historyCapacity: Int = 600) {
        self.intervalOverride = intervalOverride
        self.historyCapacity = historyCapacity
    }

    /// The per-series loop in `startIfNeeded` captures `self` weakly, so a
    /// running task does not keep the engine alive -- but the inverse isn't
    /// true either: nothing about the engine going away cancels a task that's
    /// still spinning. Without this, an engine deallocated while any series
    /// is active leaks that series' sample-and-sleep loop forever, since
    /// `stopIfIdle` (the only other canceller) requires a live `self` to run.
    deinit {
        for entry in series.values {
            entry.task?.cancel()
        }
    }

    public func register(_ sampler: AnySampler, for key: SeriesKey, cadence: SamplingCadence) {
        series[key] = Series(
            registration: Registration(sampler: sampler, cadence: cadence),
            history: RingBuffer<MetricValue>(capacity: historyCapacity)
        )
    }

    /// Series currently being sampled. Exposed for tests and diagnostics.
    public var activeSeries: Set<SeriesKey> {
        Set(series.filter { $0.value.task != nil }.keys)
    }

    public func history(for key: SeriesKey) -> [MetricValue] {
        series[key]?.history.elements ?? []
    }

    public func sampleCount(for key: SeriesKey) -> Int {
        series[key]?.history.count ?? 0
    }

    public func subscribe(to key: SeriesKey) -> AsyncStream<MetricValue> {
        let id = UUID()

        return AsyncStream { continuation in
            self.attach(id: id, key: key, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                Task { await self?.detach(id: id, key: key) }
            }
        }
    }

    private func attach(
        id: UUID,
        key: SeriesKey,
        continuation: AsyncStream<MetricValue>.Continuation
    ) {
        guard series[key] != nil else {
            continuation.finish()
            return
        }
        series[key]?.continuations[id] = continuation
        startIfNeeded(key)
    }

    private func detach(id: UUID, key: SeriesKey) {
        series[key]?.continuations.removeValue(forKey: id)
        stopIfIdle(key)
    }

    private func startIfNeeded(_ key: SeriesKey) {
        guard var entry = series[key], entry.task == nil, !entry.continuations.isEmpty else {
            return
        }

        let interval = intervalOverride ?? entry.registration.cadence.interval
        entry.task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(key)
                try? await Task.sleep(for: interval)
            }
        }
        series[key] = entry
    }

    private func stopIfIdle(_ key: SeriesKey) {
        guard var entry = series[key], entry.continuations.isEmpty else { return }
        entry.task?.cancel()
        entry.task = nil
        series[key] = entry
    }

    private func tick(_ key: SeriesKey) {
        guard let entry = series[key] else { return }

        // A sampler that throws degrades only its own series: nothing is
        // stored, nothing is published, and the schedule keeps running so the
        // series recovers on its own if the condition clears.
        guard let raw = try? entry.registration.sampler.sample() else { return }

        let value = MetricValue(
            timestamp: ProcessInfo.processInfo.systemUptime,
            uncheckedValue: raw
        )

        series[key]?.history.append(value)
        for continuation in entry.continuations.values {
            continuation.yield(value)
        }
    }
}
