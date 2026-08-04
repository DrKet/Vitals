import Darwin
import Foundation
import Testing
@testable import MetricsEngine

@Suite("Sampling overhead")
struct OverheadTests {

    /// CPU seconds consumed by this process so far.
    private func consumedCPUSeconds() -> Double {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return 0 }
        return Double(usage.ri_user_time + usage.ri_system_time) / 1_000_000_000.0
    }

    @Test("all standard samplers at 1 Hz stay under the CPU budget", .timeLimit(.minutes(1)))
    func staysUnderBudget() async throws {
        let engine = MetricsEngine()
        await StandardSamplers.registerAll(on: engine)

        var streams: [AsyncStream<MetricValue>] = []
        for key in SeriesKey.allCases {
            streams.append(await engine.subscribe(to: key))
        }

        let consumers = streams.map { stream in
            Task { for await _ in stream {} }
        }

        let cpuBefore = consumedCPUSeconds()
        let wallBefore = ProcessInfo.processInfo.systemUptime

        try await Task.sleep(for: .seconds(10))

        let cpuUsed = consumedCPUSeconds() - cpuBefore
        let wallElapsed = ProcessInfo.processInfo.systemUptime - wallBefore

        // Prove sampling actually happened before trusting the budget figure.
        // The utilisation assertion only bounds overhead from above, so a
        // registerAll that silently registered nothing would sail through it.
        //
        // .sensors is excluded from this "produced a real sample" proof: on
        // Intel Macs there is no IOHIDEventSystemClient sensor stream to read,
        // and the spec treats that absence as a legitimate, permanent,
        // hardware-dependent outcome (surfaced as "Unavailable" in the UI, not
        // fixed by retrying) rather than a bug. Every other series is
        // something the product commits to reporting on any supported Mac, so
        // it keeps the full-strength proof.
        //
        // .battery is excluded for the same reason: this machine running the
        // suite may be a desktop Mac with no `AppleSmartBattery` service at
        // all, in which case `BatterySampler.read()` legitimately and
        // permanently returns `nil` — surfaced as "Unavailable", not a bug.
        let seriesRequiringSamples = SeriesKey.allCases.filter { $0 != .sensors && $0 != .battery }
        var sampledSeries: [SeriesKey] = []
        for key in seriesRequiringSamples where await engine.sampleCount(for: key) > 0 {
            sampledSeries.append(key)
        }

        // .sensors and .battery only need to prove they were registered and
        // started ticking — `activeSeries` reflects that a sampling task
        // exists, independent of whether the sampler itself ever succeeds.
        let active = await engine.activeSeries

        consumers.forEach { $0.cancel() }

        #expect(
            sampledSeries.count == seriesRequiringSamples.count,
            "Only \(sampledSeries.count) of \(seriesRequiringSamples.count) series produced samples: \(sampledSeries)"
        )
        #expect(active.contains(.sensors), ".sensors was not registered/started")
        #expect(active.contains(.battery), ".battery was not registered/started")

        let utilisation = cpuUsed / wallElapsed

        // The spec's design goal is under 1%. The assertion threshold is 3% so
        // the test is not flaky on a loaded machine — a flaky test gets
        // deleted, which would leave no budget enforced at all. The measured
        // figure is always printed so drift toward the 1% goal stays visible
        // even while the test passes.
        print("Sampling overhead: \(String(format: "%.3f", utilisation * 100))% CPU (goal <1%, fails >3%)")
        #expect(utilisation < 0.03, "Sampling used \(utilisation * 100)% CPU")
    }

    @Test("the process series is not sampled when only CPU is subscribed")
    func processSeriesStaysIdle() async throws {
        let engine = MetricsEngine()
        await StandardSamplers.registerAll(on: engine)

        let stream = await engine.subscribe(to: .cpu)
        let consumer = Task { for await _ in stream {} }

        try await Task.sleep(for: .seconds(2))
        let active = await engine.activeSeries
        consumer.cancel()

        #expect(active.contains(.cpu))
        #expect(active.contains(.processes) == false)
    }
}
