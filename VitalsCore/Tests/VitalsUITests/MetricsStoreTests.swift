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

        // Resolved up front, while suspending is still harmless. Derived from
        // the interval the ENGINE reports, which is what the store now uses:
        // re-deriving it from the key would reintroduce exactly the duplicated
        // cadence table this design removed, and this engine runs on an
        // intervalOverride, so a key-derived cadence would disagree with what
        // sampling actually did.
        let interval = try #require(await engine.samplingInterval(for: .cpu))
        let threshold = LiveStaleness.threshold(forInterval: interval).timeInterval

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpu != nil }
        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.cpu) == false }
        #expect(await engine.activeSeries.contains(.cpu) == false)

        let stampedAt = try #require(store.cpuHistory.last?.timestamp)
        let historyCount = store.cpuHistory.count
        #expect(store.cpu != nil)

        // Advance past the threshold without waiting on wall clock — a parallel
        // suite keeps MainActor busy enough that a real sleep races with
        // drained applies and soft wait timeouts.
        //
        // `threshold` was resolved BEFORE the snapshot above on purpose: it
        // comes from the actor-isolated engine, and awaiting it here would
        // hand the MainActor back long enough for an in-flight `apply` to land,
        // moving `lastAppliedTimestamp` past the `stampedAt` this assertion
        // depends on.
        store.expireStaleLiveSamples(now: stampedAt + threshold + 0.001)

        #expect(store.cpu == nil)
        #expect(store.cpuHistory.count == historyCount)
        #expect(historyCount > 0)
    }

    @Test("live CPU survives a tick delayed by several seconds, not just one missed beat")
    func liveCPUSurvivesADelayedTick() async throws {
        let engine = await engineYielding([Self.load(0.4)])
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.cpu) }
        try await waitUntil { store.cpu != nil }
        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.cpu) == false }

        let stampedAt = try #require(store.cpuHistory.last?.timestamp)
        // Four seconds — twice what a bare 2x-of-1s threshold would have
        // tolerated. `MetricsStore` is @MainActor, and this project measured
        // concurrent window renders starving a main-actor poll loop for over
        // two seconds, so a tick arriving this late is a real scenario. Blanking
        // the largest number on screen for it, then restoring it a moment
        // later, is a worse lie than showing a four-second-old figure.
        store.expireStaleLiveSamples(now: stampedAt + 4.0)
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

        // Resolved before the snapshot below: awaiting the actor-isolated
        // engine mid-assertion hands the MainActor back, and an in-flight
        // `apply` then moves the timestamps the assertions depend on.
        let interval = try #require(await engine.samplingInterval(for: .network))
        let threshold = LiveStaleness.threshold(forInterval: interval).timeInterval

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
        let now = max(netStamped, diskStamped) + threshold + 0.001
        store.expireStaleLiveSamples(now: now)

        #expect(store.network == nil)
        #expect(store.diskIO == nil)
        #expect(store.networkHistory.count == netHistory)
        #expect(store.diskIOHistory.count == diskHistory)
        #expect(netHistory > 0)
        #expect(diskHistory > 0)
    }

    @Test("volume capacity does not expire, however long sampling has been stopped")
    func volumesNeverExpire() async throws {
        // The store deliberately keeps no history for volumes because capacity
        // "changes over minutes, not seconds". A free-space figure a few
        // seconds old is not stale in any sense a reader cares about, and
        // expiring it would blank the Storage page's volume bars and capacity
        // rows on any pause. Every other live field is a rate or a utilisation,
        // where seconds old genuinely is out of date.
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let volumes = [
            Volume(name: "Macintosh HD", totalBytes: 500_000_000_000,
                   availableBytes: 200_000_000_000, isInternal: true)
        ]
        await engine.register(AnySampler { volumes }, for: .storage, cadence: .fast)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.storage) }
        try await waitUntil { store.volumes != nil }
        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.storage) == false }

        // An hour later — far past any threshold that expires a rate.
        store.expireStaleLiveSamples(now: ProcessInfo.processInfo.systemUptime + 3_600)
        #expect(store.volumes?.count == 1)
        #expect(store.volumes?.first?.name == "Macintosh HD")
    }

    @Test("publishes the latest process listing")
    func publishesProcesses() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let snapshot = ProcessSnapshot(
            pid: 42, parentPID: 1, name: "loginwindow", userID: 501,
            memoryFootprintBytes: 12_000_000, cpuTimeSeconds: 3.5, threadCount: 4,
            diskBytesRead: 1024, diskBytesWritten: 2048, architecture: .native
        )
        let sample = ProcessSeriesSample(processes: [snapshot], cpuUsage: [42: 0.25])
        await engine.register(AnySampler { sample }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()

        #expect(store.processes?.processes.count == 1)
        #expect(store.processes?.processes.first?.name == "loginwindow")
        #expect(abs((store.processes?.cpuUsage[42] ?? 0) - 0.25) < 1e-9)
    }

    @Test("a wrong-type processes payload is ignored rather than crashing")
    func wrongTypeProcessPayloadIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a process sample" }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.processes) }
        try await waitUntilAsync { await engine.sampleCount(for: .processes) > 0 }
        task.cancel()

        #expect(store.processes == nil)
    }

    @Test("live process listing clears once its sample ages past the staleness threshold")
    func liveProcessesClearWhenStale() async throws {
        // .processes was moved into expiresWhenStale's true branch and given a
        // clearLiveSample case in the same change. Unlike CPU/throughput there
        // is no history array here to assert survives — the store deliberately
        // keeps none for processes (a 600-sample ring of ~600 processes would
        // be 360,000 snapshots) — so this only has the "clears" half to prove.
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let snapshot = ProcessSnapshot(
            pid: 42, parentPID: 1, name: "loginwindow", userID: 501,
            memoryFootprintBytes: 12_000_000, cpuTimeSeconds: 3.5, threadCount: 4,
            diskBytesRead: 1024, diskBytesWritten: 2048, architecture: .native
        )
        let sample = ProcessSeriesSample(processes: [snapshot], cpuUsage: [42: 0.25])
        await engine.register(AnySampler { sample }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()
        try await waitUntilAsync { await engine.activeSeries.contains(.processes) == false }

        // The store keeps no history for processes, so unlike the CPU/network
        // tests there is no synchronous store-side timestamp to snapshot.
        // The engine's own retained history is the next best source. Both
        // reads here are actor awaits, resolved together right before the
        // synchronous assertions below and with no further await in between —
        // by this point the subscription is confirmed torn down (the
        // `waitUntilAsync` above), so nothing is left running that could move
        // `store.processes` out from under the snapshot.
        let interval = try #require(await engine.samplingInterval(for: .processes))
        let threshold = LiveStaleness.threshold(forInterval: interval).timeInterval
        let stampedAt = try #require(await engine.history(for: .processes).last?.timestamp)

        #expect(store.processes != nil)

        store.expireStaleLiveSamples(now: stampedAt + threshold + 0.001)

        #expect(store.processes == nil)
    }

    @Test("the staleness gate reads the engine's real interval, not one derived from the key")
    func stalenessUsesTheEnginesInterval() async {
        // The cadence for a key lives in StandardSamplers, and intervalOverride
        // can collapse it. A copy of that table in the store would drift
        // silently — a wrong threshold only shows up as readings expiring too
        // early or too late, which no test would catch.
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { [Volume]() }, for: .storage, cadence: .slow)

        // Registered .slow (5s nominal) but overridden to 5ms: the engine
        // reports what it actually does, not what the cadence implies.
        #expect(await engine.samplingInterval(for: .storage) == .milliseconds(5))
        #expect(await engine.samplingInterval(for: .cpu) == nil)
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
