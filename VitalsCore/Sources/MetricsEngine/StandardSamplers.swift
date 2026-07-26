import Foundation
import SystemMetrics

/// Wires the concrete samplers into an engine.
///
/// Stateful trackers — the ones that turn cumulative counters into rates — are
/// held here so each series keeps its own history across ticks.
public enum StandardSamplers {

    public static func registerAll(on engine: MetricsEngine) async {
        await engine.register(cpuSampler(), for: .cpu, cadence: .fast)
        await engine.register(memorySampler(), for: .memory, cadence: .fast)
        await engine.register(gpuSampler(), for: .gpu, cadence: .fast)
        await engine.register(networkSampler(), for: .network, cadence: .fast)
        await engine.register(storageSampler(), for: .storage, cadence: .fast)
        await engine.register(processSampler(), for: .processes, cadence: .slow)
        await engine.register(diskIOSampler(), for: .diskIO, cadence: .fast)
    }

    private enum SamplerError: Error {
        case unavailable
    }

    private static func cpuSampler() -> AnySampler {
        let state = SamplerState<[CPUTicks]>([])
        return AnySampler {
            guard let current = CPUTickReader.read() else { throw SamplerError.unavailable }
            let previous = state.withLock { value -> [CPUTicks] in
                let old = value
                value = current
                return old
            }
            guard let load = CPULoadCalculator.load(from: previous, to: current) else {
                throw SamplerError.unavailable
            }
            return load
        }
    }

    private static func memorySampler() -> AnySampler {
        AnySampler {
            guard let sample = MemorySampler.read() else { throw SamplerError.unavailable }
            return sample
        }
    }

    private static func gpuSampler() -> AnySampler {
        AnySampler {
            let samples = GPUSampler.read()
            guard !samples.isEmpty else { throw SamplerError.unavailable }
            return samples
        }
    }

    private static func networkSampler() -> AnySampler {
        let tracker = SamplerState(NetworkThroughputTracker())
        return AnySampler {
            let counters = NetworkSampler.counters()
            let now = ProcessInfo.processInfo.systemUptime
            let throughput = tracker.withLock { $0.update(counters, at: now) }
            guard !throughput.isEmpty else { throw SamplerError.unavailable }
            return throughput
        }
    }

    private static func storageSampler() -> AnySampler {
        AnySampler {
            let volumes = StorageSampler.volumes()
            guard !volumes.isEmpty else { throw SamplerError.unavailable }
            return volumes
        }
    }

    private static func processSampler() -> AnySampler {
        let tracker = SamplerState(ProcessCPUTracker())
        return AnySampler {
            let processes = ProcessSampler.snapshot()
            // A machine with zero processes does not exist; an empty snapshot
            // means the underlying sysctl calls failed, not that the system is
            // idle. Degrade like every other sampler rather than publishing a
            // fabricated "no processes" state.
            guard !processes.isEmpty else { throw SamplerError.unavailable }
            let now = ProcessInfo.processInfo.systemUptime
            let usage = tracker.withLock { $0.update(processes, at: now) }
            return ProcessSeriesSample(processes: processes, cpuUsage: usage)
        }
    }

    private static func diskIOSampler() -> AnySampler {
        let tracker = SamplerState(DiskThroughputTracker())
        return AnySampler {
            let counters = StorageSampler.ioCounters()
            let now = ProcessInfo.processInfo.systemUptime
            let throughput = tracker.withLock { $0.update(counters, at: now) }
            guard !throughput.isEmpty else { throw SamplerError.unavailable }
            return throughput
        }
    }
}

/// A process listing paired with the CPU percentages derived from it.
public struct ProcessSeriesSample: Sendable {
    public let processes: [ProcessSnapshot]
    public let cpuUsage: [pid_t: Double]
}

/// Minimal mutual-exclusion box for sampler state that must survive across
/// ticks. `AnySampler`'s closure is `@Sendable`, so captured state must be
/// synchronised. Named to avoid colliding with `Synchronization.Mutex`.
final class SamplerState<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
