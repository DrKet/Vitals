import Foundation
import SystemMetrics

/// One row of the process table: the values it shows, and how they are worded.
///
/// Deliberately free of SwiftUI, so every formatting and absence decision is a
/// pure function with a direct test — the same split the hardware pages use.
public struct ProcessRow: Identifiable, Sendable, Equatable {

    public var id: pid_t { pid }

    public let pid: pid_t
    public let name: String
    public let userName: String

    /// `1.0` means one core fully saturated, so a process spread across four
    /// cores reads `4.0`. `nil` when this process' CPU time is unreadable —
    /// which is true of roughly a third of live processes, typically other
    /// users' and root's.
    public let cpuFraction: Double?

    public let memoryBytes: UInt64?
    public let threadCount: Int?
    public let cpuTimeSeconds: Double?
    public let diskReadBytes: UInt64?
    public let diskWrittenBytes: UInt64?
    public let architecture: ProcessArchitecture
    /// The row's process start time, carried from `ProcessSnapshot` so the
    /// selection can build a `ProcessIdentity` (see that type).
    public let startTimeSeconds: Double

    public init(
        pid: pid_t,
        name: String,
        userName: String,
        cpuFraction: Double?,
        memoryBytes: UInt64?,
        threadCount: Int?,
        cpuTimeSeconds: Double?,
        diskReadBytes: UInt64?,
        diskWrittenBytes: UInt64?,
        architecture: ProcessArchitecture,
        startTimeSeconds: Double
    ) {
        self.pid = pid
        self.name = name
        self.userName = userName
        self.cpuFraction = cpuFraction
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.cpuTimeSeconds = cpuTimeSeconds
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.architecture = architecture
        self.startTimeSeconds = startTimeSeconds
    }

    public init(snapshot: ProcessSnapshot, cpuFraction: Double?, userName: String) {
        self.init(
            pid: snapshot.pid,
            name: snapshot.name,
            userName: userName,
            cpuFraction: cpuFraction,
            memoryBytes: snapshot.memoryFootprintBytes,
            threadCount: snapshot.threadCount,
            cpuTimeSeconds: snapshot.cpuTimeSeconds,
            diskReadBytes: snapshot.diskBytesRead,
            diskWrittenBytes: snapshot.diskBytesWritten,
            architecture: snapshot.architecture,
            startTimeSeconds: snapshot.startTimeSeconds
        )
    }

    /// This row's process identity, for the selection binding.
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeSeconds: startTimeSeconds)
    }

    // MARK: Display

    /// Absence in a table cell, worded exactly as `MetricTile` words it.
    /// `ProcessRowTests.absenceMatchesTileVocabulary` holds the two together —
    /// `PageConsistencyTests` ties `MetricTile` to `StatRow`, but knows nothing
    /// of this type.
    public static func displayValue(_ value: String?) -> String {
        MetricTile.displayValue(value)
    }

    /// Activity Monitor's scale: a process saturating four cores reads 402%,
    /// not 100%. Clamping to 100 would hide the thing you opened the table for.
    public static func formatCPU(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        let percentage = (fraction * 100).rounded()
        // `Int(_:)` on a non-finite or out-of-range `Double` traps. A NaN or
        // overflowing fraction is not a measurement — the honest rendering is
        // the same em dash absence already gets, not a crash.
        guard let wholePercentage = Int(exactly: percentage) else { return nil }
        return "\(wholePercentage)%"
    }

    public static func formatMemory(_ bytes: UInt64?) -> String? {
        Vitals.formatByteCount(bytes)
    }

    public static func formatCount(_ count: Int?) -> String? {
        guard let count else { return nil }
        return "\(count)"
    }

    /// `h:mm:ss`. Hours are not zero-padded and are not capped at 24 — a
    /// long-lived daemon legitimately accumulates hundreds of hours.
    public static func formatCPUTime(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }

    public static func formatArchitecture(_ architecture: ProcessArchitecture) -> String {
        switch architecture {
        case .native: "Native"
        case .translated: "Rosetta"
        }
    }
}
