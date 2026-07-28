import Foundation
import Testing
@testable import MetricsEngine

/// Counts how many times it was asked for a value, so tests can assert that
/// sampling only happens while something is subscribed.
final class CountingSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _shouldThrow = false

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func setShouldThrow(_ value: Bool) {
        lock.withLock { _shouldThrow = value }
    }

    func sample() throws -> Double {
        try lock.withLock {
            _callCount += 1
            if _shouldThrow { throw SamplerError.failed }
            return Double(_callCount)
        }
    }

    enum SamplerError: Error { case failed }
}

/// Polls `condition` until it returns `true` or `timeout` elapses, checking
/// on `pollInterval` cadence. Returns the final result of `condition`, so a
/// caller that wraps this in `#expect` gets an ordinary, informative test
/// failure -- not a hang -- if a genuine regression stops the condition from
/// ever becoming true.
private func waitUntil(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}

@Suite("MetricsEngine")
struct MetricsEngineTests {

    @Test("no series is active before anything subscribes")
    func nothingActiveInitially() async {
        let engine = MetricsEngine()
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        #expect(await engine.activeSeries.isEmpty)
    }

    @Test("does not sample a series with no subscribers")
    func doesNotSampleWithoutSubscribers() async throws {
        let engine = MetricsEngine()
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        try await Task.sleep(for: .milliseconds(300))
        #expect(sampler.callCount == 0)
    }

    @Test("starts sampling when a subscriber arrives")
    func startsOnSubscription() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        let stream = await engine.subscribe(to: .cpu)
        var received = 0
        for await _ in stream {
            received += 1
            if received == 3 { break }
        }

        #expect(received == 3)
        #expect(sampler.callCount >= 3)
        #expect(await engine.activeSeries.contains(.cpu))
    }

    @Test("stops sampling when the last subscriber leaves")
    func stopsWhenLastSubscriberLeaves() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        let stream = await engine.subscribe(to: .cpu)

        // Mirror the pattern real consumers use: a view or widget owns a Task
        // that iterates the stream for as long as it's visible, and cancels
        // that Task when it goes away. `AsyncStream.onTermination` only fires
        // on an explicit `finish()` or on cancellation of the *consuming*
        // Task -- breaking out of a `for await` loop while the stream value
        // is still in scope does neither, so it can't be used to exercise
        // detach here.
        let consumer = Task {
            for await _ in stream {}
        }

        // Sampling should be running while the subscriber is attached.
        let sampledWhileAttached = await waitUntil { sampler.callCount >= 3 }
        #expect(sampledWhileAttached)
        #expect(await engine.activeSeries.contains(.cpu))

        consumer.cancel()

        // Cancellation propagates asynchronously: it unblocks the stream's
        // iteration, which fires `onTermination`, which hops onto the engine
        // to detach and cancel the per-series sampling task. Poll for that
        // rather than sleeping a fixed amount, but still fail (rather than
        // hang) if it never happens.
        let stoppedInTime = await waitUntil { await engine.activeSeries.contains(.cpu) == false }
        #expect(stoppedInTime)

        let countAfterStop = sampler.callCount
        try await Task.sleep(for: .milliseconds(200))

        #expect(sampler.callCount == countAfterStop)
        #expect(await engine.activeSeries.contains(.cpu) == false)
    }

    @Test("keeps sampling for the remaining subscriber when one departs")
    func keepsSamplingForRemainingSubscriber() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        let first = await engine.subscribe(to: .cpu)
        let second = await engine.subscribe(to: .cpu)

        // Mirror the pattern real consumers use, same as
        // `stopsWhenLastSubscriberLeaves`: a view or widget owns a Task that
        // iterates the stream for as long as it's visible, and cancels that
        // Task when it goes away. Breaking out of a `for await` loop while
        // the stream value is still in scope does not fire `onTermination`,
        // so it can't be used to exercise a genuine departure here -- only
        // consuming-Task cancellation does.
        let firstConsumer = Task {
            for await _ in first {}
        }
        let secondConsumer = Task {
            for await _ in second {}
        }

        // Sampling should be running while both subscribers are attached.
        let sampledWithBoth = await waitUntil { sampler.callCount >= 3 }
        #expect(sampledWithBoth)
        #expect(await engine.activeSeries.contains(.cpu))

        firstConsumer.cancel()

        // Give the first subscriber's detach a chance to land. Detaching one
        // of two subscribers must not stop the series -- only the departure
        // of the *last* one does that (covered by
        // `stopsWhenLastSubscriberLeaves`). Poll on the surviving
        // subscriber's count actually advancing, rather than sleeping a
        // fixed amount, so this doesn't hang if a regression stalls it, but
        // still gives real time for the (incorrect) idle path to kick in if
        // one existed.
        let countAfterFirstLeaves = sampler.callCount
        let keptSamplingForSecond = await waitUntil {
            sampler.callCount > countAfterFirstLeaves
        }
        #expect(keptSamplingForSecond)
        #expect(await engine.activeSeries.contains(.cpu))

        secondConsumer.cancel()

        let bothGoneStoppedIt = await waitUntil { await engine.activeSeries.contains(.cpu) == false }
        #expect(bothGoneStoppedIt)
    }

    @Test("subscribing to one series never samples another")
    func doesNotSampleUnrelatedSeries() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let cpu = CountingSampler()
        let processes = CountingSampler()
        await engine.register(AnySampler { try cpu.sample() }, for: .cpu, cadence: .fast)
        await engine.register(AnySampler { try processes.sample() }, for: .processes, cadence: .slow)

        let stream = await engine.subscribe(to: .cpu)
        var received = 0
        for await _ in stream {
            received += 1
            if received == 3 { break }
        }

        #expect(cpu.callCount >= 3)
        #expect(processes.callCount == 0)
    }

    @Test("a throwing sampler does not stop the engine or other series")
    func throwingSamplerIsIsolated() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let failing = CountingSampler()
        failing.setShouldThrow(true)
        let healthy = CountingSampler()

        await engine.register(AnySampler { try failing.sample() }, for: .gpu, cadence: .fast)
        await engine.register(AnySampler { try healthy.sample() }, for: .cpu, cadence: .fast)

        let failingStream = await engine.subscribe(to: .gpu)
        let healthyStream = await engine.subscribe(to: .cpu)

        var healthyReceived = 0
        for await _ in healthyStream {
            healthyReceived += 1
            if healthyReceived == 3 { break }
        }

        #expect(healthyReceived == 3)

        // The failing series' sampling task runs independently of the
        // healthy one -- both start microseconds apart, but under parallel
        // test execution (several other 20ms-cadence tasks competing for the
        // same cooperative thread pool) they aren't guaranteed to have ticked
        // the same number of times by the instant the healthy series hits
        // its target. Poll instead of asserting immediately, with a bounded
        // timeout so a genuine regression (the throwing sampler's task
        // getting disabled) still fails the test.
        let failingKeptRetrying = await waitUntil { failing.callCount >= 3 }
        #expect(failingKeptRetrying)  // kept trying
        #expect(await engine.sampleCount(for: .gpu) == 0)  // but stored nothing

        _ = failingStream
    }

    @Test("history is bounded by the ring buffer capacity")
    func historyIsBounded() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(2), historyCapacity: 5)
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        let stream = await engine.subscribe(to: .cpu)
        var received = 0
        for await _ in stream {
            received += 1
            if received == 20 { break }
        }

        #expect(await engine.history(for: .cpu).count <= 5)
    }

    @Test("re-registering a live series cancels the previous sampling task")
    func reregisterCancelsPreviousTask() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let first = CountingSampler()
        let second = CountingSampler()
        await engine.register(AnySampler { try first.sample() }, for: .cpu, cadence: .fast)

        let stream = await engine.subscribe(to: .cpu)
        let consumer = Task {
            for await _ in stream {}
        }

        let sampledBeforeReplace = await waitUntil { first.callCount >= 3 }
        #expect(sampledBeforeReplace)

        // Replace while the first task is still spinning. The new Series has
        // no subscribers, so nothing should start a fresh loop — and the old
        // loop must be cancelled, or its next `tick` would sample `second`
        // forever despite nobody being subscribed.
        await engine.register(AnySampler { try second.sample() }, for: .cpu, cadence: .fast)

        let countAfterReplace = second.callCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(second.callCount == countAfterReplace)
        #expect(await engine.activeSeries.contains(.cpu) == false)

        consumer.cancel()
    }
}
