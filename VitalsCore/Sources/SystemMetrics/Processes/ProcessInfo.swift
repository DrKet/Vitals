import Darwin
import Foundation

public enum ProcessArchitecture: Sendable, Equatable {
    case native
    /// Running under Rosetta translation.
    case translated
}

public struct ProcessSnapshot: Sendable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let name: String
    public let userID: uid_t

    /// `ri_phys_footprint`. This is what Activity Monitor's Memory column
    /// shows. RSS is deliberately not used: it materially overstates memory on
    /// macOS and would make Vitals disagree with every other tool.
    ///
    /// `nil` when `proc_pid_rusage` failed — typically because the process
    /// exited mid-scan, or is protected. Never `0`, which would misreport a
    /// running process as using no memory.
    public let memoryFootprintBytes: UInt64?

    public let cpuTimeSeconds: Double
    /// `nil` when `proc_pidinfo` failed for this process.
    public let threadCount: Int?
    /// `nil` when `proc_pid_rusage` failed for this process.
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?
    public let architecture: ProcessArchitecture

    public init(
        pid: pid_t, parentPID: pid_t, name: String, userID: uid_t,
        memoryFootprintBytes: UInt64?, cpuTimeSeconds: Double, threadCount: Int?,
        diskBytesRead: UInt64?, diskBytesWritten: UInt64?,
        architecture: ProcessArchitecture
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.userID = userID
        self.memoryFootprintBytes = memoryFootprintBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.threadCount = threadCount
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.architecture = architecture
    }
}

/// Converts cumulative per-process CPU time into a utilisation fraction.
/// `1.0` means one core fully saturated; a process on four cores reports `4.0`.
public struct ProcessCPUTracker: Sendable {
    private var previous: [pid_t: (cpuTime: Double, timestamp: TimeInterval)] = [:]

    public init() {}

    public mutating func update(
        _ processes: [ProcessSnapshot],
        at timestamp: TimeInterval
    ) -> [pid_t: Double] {
        var result: [pid_t: Double] = [:]
        var current: [pid_t: (cpuTime: Double, timestamp: TimeInterval)] = [:]

        for process in processes {
            current[process.pid] = (process.cpuTimeSeconds, timestamp)

            guard let last = previous[process.pid] else { continue }
            let elapsed = timestamp - last.timestamp
            guard elapsed > 0 else { continue }

            // Decreasing CPU time means the PID was recycled onto a new process.
            guard process.cpuTimeSeconds >= last.cpuTime else { continue }

            result[process.pid] = (process.cpuTimeSeconds - last.cpuTime) / elapsed
        }

        // Replacing rather than merging is what makes an exited PID start fresh
        // when the number is later reused.
        previous = current
        return result
    }
}
