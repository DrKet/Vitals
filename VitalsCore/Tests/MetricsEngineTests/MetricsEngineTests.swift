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
        var received = 0
        for await _ in stream {
            received += 1
            if received == 2 { break }
        }

        try await Task.sleep(for: .milliseconds(100))
        let countAfterCancel = sampler.callCount
        try await Task.sleep(for: .milliseconds(200))

        #expect(sampler.callCount == countAfterCancel)
        #expect(await engine.activeSeries.contains(.cpu) == false)
    }

    @Test("keeps sampling while a second subscriber remains")
    func keepsSamplingForRemainingSubscriber() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(20))
        let sampler = CountingSampler()
        await engine.register(AnySampler { try sampler.sample() }, for: .cpu, cadence: .fast)

        let first = await engine.subscribe(to: .cpu)
        let second = await engine.subscribe(to: .cpu)

        var firstCount = 0
        for await _ in first {
            firstCount += 1
            if firstCount == 2 { break }
        }

        var secondCount = 0
        for await _ in second {
            secondCount += 1
            if secondCount == 2 { break }
        }

        #expect(secondCount == 2)
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
        #expect(failing.callCount >= 3)  // kept trying
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
}
