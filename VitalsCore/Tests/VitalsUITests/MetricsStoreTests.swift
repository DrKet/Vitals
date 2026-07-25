import Foundation
import MetricsEngine
import SystemMetrics
import Testing
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
}

/// Vends prerecorded samples, then throws so the series goes quiet.
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
