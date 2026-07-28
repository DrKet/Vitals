import Foundation
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("MetricsStore")
struct MetricsStoreTests {

    /// An engine preloaded with one controllable sampler, so store behaviour is
    /// testable without touching real hardware.
    private func engineYielding(_ values: [CPULoadSample]) async -> MetricsEngine {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let box = ValueBox(values)
        await engine.register(
            AnySampler { try box.next() },
            for: .cpu,
            cadence: .fast
        )
        return engine
    }

    private static func load(_ busy: Double) -> CPULoadSample {
        CPULoadSample(cores: [CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0)])
    }

    @Test("starts with no value, because nothing has been sampled yet")
    func startsEmpty() async throws {
        let engine = await engineYielding([])
        let store = MetricsStore(engine: engine, profile: nil)
        #expect(store.cpu == nil)
        #expect(store.cpuHistory.isEmpty)
    }

    @Test("publishes typed CPU values from the untyped stream")
    func publishesTypedValues() async throws {
        let engine = await engineYielding([Self.load(0.25), Self.load(0.5)])
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.count >= 2 }
        task.cancel()

        #expect(store.cpu?.total == 0.5)
        #expect(store.cpuHistory.count >= 2)
    }

    @Test("history is capped so a long-running app cannot grow without bound")
    func historyIsCapped() async throws {
        let engine = await engineYielding(Array(repeating: Self.load(0.1), count: 100))
        let store = MetricsStore(engine: engine, profile: nil, historyLimit: 5)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.count == 5 }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.cpuHistory.count == 5)
    }

    @Test("a payload of the wrong type is ignored rather than crashing")
    func wrongTypeIsIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a CPU sample" }, for: .cpu, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.cpu == nil)
        #expect(store.cpuHistory.isEmpty)
    }

    @Test("two concurrent subscribers to one series do not duplicate its history")
    func concurrentSubscribersDoNotDuplicateHistory() async throws {
        // The Overview grid and a hardware page overlap during a sidebar switch,
        // and both stream .cpu. The engine fans one sample out to both, so the
        // store must fold each tick in exactly once.
        let engine = await engineYielding(Array(repeating: Self.load(0.3), count: 200))
        let store = MetricsStore(engine: engine, profile: nil)

        let first = Task { await store.stream(.cpu) }
        let second = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.count >= 6 }

        // Both snapshots are taken back-to-back, before cancelling either
        // task. `Task.cancel()` is asynchronous — the stream doesn't stop
        // instantly — so if `elapsedTicks` were read after cancelling (as
        // this used to do), ticks landing in that window would inflate
        // `elapsedTicks` relative to the already-captured `observed`,
        // weakening the assertion in the passing direction and letting a
        // real duplication bug slip through.
        let observed = store.cpuHistory.count
        let elapsedTicks = await engine.sampleCount(for: .cpu)
        first.cancel()
        second.cancel()

        // Both tasks ran for the same wall-clock window against a 5ms interval.
        // If each subscriber appended independently, history would be ~2x the
        // number of ticks that actually elapsed.
        #expect(observed <= elapsedTicks)
    }

    @Test("a nonsensical history limit trims instead of trapping")
    func nonsensicalLimitDoesNotTrap() async throws {
        let engine = await engineYielding(Array(repeating: Self.load(0.1), count: 20))
        let store = MetricsStore(engine: engine, profile: nil, historyLimit: 0)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.isEmpty == false }
        task.cancel()

        #expect(store.cpuHistory.count == 1)
    }

    @Test("cancelling the streaming task releases the engine subscription")
    func cancellationReleasesSubscription() async throws {
        let engine = await engineYielding(Array(repeating: Self.load(0.1), count: 100))
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpuHistory.isEmpty == false }
        #expect(await engine.activeSeries.contains(.cpu))

        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.cpu) == false }
    }

    @Test("publishes GPU samples with history")
    func publishesGPU() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let sample = GPUSample(
            deviceUtilisation: 0.4, rendererUtilisation: 0.3,
            tilerUtilisation: 0.1, inUseMemoryBytes: 1000, allocatedMemoryBytes: 2000
        )
        await engine.register(AnySampler { [sample] }, for: .gpu, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.gpu) }
        try await waitUntil { store.gpuHistory.count >= 2 }
        task.cancel()

        #expect(store.gpu?.first?.deviceUtilisation == 0.4)
        #expect(store.gpuHistory.isEmpty == false)
    }

    @Test("publishes the latest volumes")
    func publishesLatestVolumes() async throws {
        // Note on the name: this proves the latest reading arrives. That
        // volumes accumulate *no* history is guaranteed structurally — there is
        // no `volumesHistory` property to grow — not by anything observable
        // here, so the test does not claim to prove it.
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let volume = Volume(name: "Macintosh HD", totalBytes: 1000, availableBytes: 400, isInternal: true)
        await engine.register(AnySampler { [volume] }, for: .storage, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.storage) }
        try await waitUntil { store.volumes != nil }
        task.cancel()

        // Capacity moves over minutes; a 600-sample ring of identical values
        // would be waste, so only the latest reading is kept.
        #expect(store.volumes?.first?.name == "Macintosh HD")
    }

    @Test("publishes network throughput with history")
    func publishesNetwork() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let throughput = ["en0": NetworkThroughput(bytesInPerSecond: 2048, bytesOutPerSecond: 1024)]
        await engine.register(AnySampler { throughput }, for: .network, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.network) }
        try await waitUntil { store.networkHistory.count >= 2 }
        task.cancel()

        #expect(store.network?["en0"]?.bytesInPerSecond == 2048)
    }

    @Test("publishes disk IO throughput with history")
    func publishesDiskIO() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let throughput = ["disk0": DiskThroughput(bytesReadPerSecond: 2048, bytesWrittenPerSecond: 1024)]
        await engine.register(AnySampler { throughput }, for: .diskIO, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.diskIO) }
        try await waitUntil { store.diskIOHistory.count >= 2 }
        task.cancel()

        #expect(store.diskIO?["disk0"]?.bytesReadPerSecond == 2048)
    }

    @Test("a wrong-typed payload on a new series is ignored, not crashed on")
    func wrongTypeOnNewSeriesIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a GPU sample" }, for: .gpu, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.gpu) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.gpu == nil)
        #expect(store.gpuHistory.isEmpty)
    }

    @Test("a wrong-typed storage payload is ignored, not crashed on")
    func wrongTypeOnStorageIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a volume list" }, for: .storage, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.storage) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.volumes == nil)
    }

    @Test("a wrong-typed network payload is ignored, not crashed on")
    func wrongTypeOnNetworkIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not network throughput" }, for: .network, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.network) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        #expect(store.network == nil)
        #expect(store.networkHistory.isEmpty)
    }

    @Test("live CPU clears after 2× Fast cadence once sampling stops; history is kept")
    func liveCPUClearsWhenStaleButHistoryRemains() async throws {
        // Primaries must not keep an hour-old reading styled as live after the
        // page unsubscribes. Charts still need the retained history to gap-break.
        let engine = await engineYielding([Self.load(0.4)])
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpu != nil }
        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.cpu) == false }
        #expect(await engine.activeSeries.contains(.cpu) == false)

        let stampedAt = try #require(store.cpuHistory.last?.timestamp)
        let historyCount = store.cpuHistory.count
        #expect(store.cpu != nil)

        // Advance past 2× Fast without waiting on wall clock — a parallel
        // suite keeps MainActor busy enough that a real 2s sleep races with
        // drained applies and soft wait timeouts.
        let threshold = SamplingCadence.fast.liveStalenessThreshold.timeInterval
        store.expireStaleLiveSamples(now: stampedAt + threshold + 0.001)

        #expect(store.cpu == nil)
        #expect(store.cpuHistory.count == historyCount)
        #expect(historyCount > 0)
    }

    @Test("live CPU stays present within one missed Fast tick after sampling stops")
    func liveCPUSurvivesOneMissedTickWindow() async throws {
        let engine = await engineYielding([Self.load(0.4)])
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpu != nil }
        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.cpu) == false }

        let stampedAt = try #require(store.cpuHistory.last?.timestamp)
        // Half the staleness window — still inside the one-missed-tick tolerance.
        store.expireStaleLiveSamples(
            now: stampedAt + SamplingCadence.fast.interval.timeInterval
        )
        #expect(store.cpu != nil)
    }

    @Test("live network and diskIO clear when stale without wiping history")
    func liveThroughputClearsWhenStale() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let network = ["en0": NetworkThroughput(bytesInPerSecond: 100, bytesOutPerSecond: 50)]
        let disk = ["disk0": DiskThroughput(bytesReadPerSecond: 200, bytesWrittenPerSecond: 100)]
        await engine.register(AnySampler { network }, for: .network, cadence: .fast)
        await engine.register(AnySampler { disk }, for: .diskIO, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let netTask = Task { await store.stream(.network) }
        let diskTask = Task { await store.stream(.diskIO) }
        try await waitUntil { store.network != nil && store.diskIO != nil }
        netTask.cancel()
        diskTask.cancel()
        try await waitUntilAsync {
            let active = await engine.activeSeries
            return !active.contains(.network) && !active.contains(.diskIO)
        }

        let netStamped = try #require(store.networkHistory.last?.timestamp)
        let diskStamped = try #require(store.diskIOHistory.last?.timestamp)
        let netHistory = store.networkHistory.count
        let diskHistory = store.diskIOHistory.count
        let threshold = SamplingCadence.fast.liveStalenessThreshold.timeInterval
        let now = max(netStamped, diskStamped) + threshold + 0.001
        store.expireStaleLiveSamples(now: now)

        #expect(store.network == nil)
        #expect(store.diskIO == nil)
        #expect(store.networkHistory.count == netHistory)
        #expect(store.diskIOHistory.count == diskHistory)
        #expect(netHistory > 0)
        #expect(diskHistory > 0)
    }
}

/// Vends prerecorded samples, then repeats the final one forever once
/// exhausted — it only throws if constructed with an empty array to begin
/// with, in which case there is no "final sample" to fall back to.
/// `historyIsCapped` depends on the repeating behaviour: it needs the stream
/// to keep producing ticks past its 100 recorded samples so history actually
/// fills past the cap, rather than the series going quiet once the recording
/// runs out.
final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [CPULoadSample]
    private let last: CPULoadSample?

    init(_ values: [CPULoadSample]) {
        remaining = values
        last = values.last
    }

    enum Empty: Error { case exhausted }

    func next() throws -> CPULoadSample {
        try lock.withLock {
            if remaining.isEmpty {
                guard let last else { throw Empty.exhausted }
                return last
            }
            return remaining.removeFirst()
        }
    }
}

/// Polls a main-actor condition with a bounded timeout, so a regression fails
/// rather than hanging.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition not met within \(timeout)")
}

@MainActor
func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition not met within \(timeout)")
}
