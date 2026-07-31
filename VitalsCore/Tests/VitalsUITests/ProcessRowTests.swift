import Foundation
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process row")
struct ProcessRowTests {

    // MARK: Absence

    @Test("every optional field formats as nil when unreadable, never as zero")
    func absentFieldsFormatAsNil() {
        // A third of live processes have unreadable CPU time. Formatting any of
        // these as "0" would report a running process as idle.
        #expect(ProcessRow.formatCPU(nil) == nil)
        #expect(ProcessRow.formatMemory(nil) == nil)
        #expect(ProcessRow.formatCount(nil) == nil)
        #expect(ProcessRow.formatCPUTime(nil) == nil)
    }

    @Test("absence renders as the same em dash the tiles use")
    func absenceMatchesTileVocabulary() {
        #expect(ProcessRow.displayValue(nil) == MetricTile.displayValue(nil))
        #expect(ProcessRow.displayValue("41%") == "41%")
    }

    @Test("a genuine zero is shown as zero, not as absent")
    func genuineZeroIsNotAbsence() {
        // A process really using no CPU this interval is a measurement.
        #expect(ProcessRow.formatCPU(0) == "0%")
        #expect(ProcessRow.formatCount(0) == "0")
    }

    // MARK: CPU

    @Test("CPU is shown Activity Monitor style, where four saturated cores read 400%")
    func cpuUsesActivityMonitorScale() {
        #expect(ProcessRow.formatCPU(0.412) == "41%")
        #expect(ProcessRow.formatCPU(1.0) == "100%")
        #expect(ProcessRow.formatCPU(4.02) == "402%")
    }

    @Test("an unrepresentable CPU fraction renders as absent instead of trapping")
    func unrepresentableCPUFractionDoesNotTrap() {
        // `Int(Double)` traps on a non-finite or out-of-range value. Unreachable
        // from a live sampler today, but this is the column most likely to
        // eventually carry a computed float, and a trap-on-bad-input here would
        // take the whole page down. An unrepresentable value is not a
        // measurement, so — same as any other absent reading — the honest
        // rendering is `nil` (the em dash), never a crash and never "0%".
        #expect(ProcessRow.formatCPU(.nan) == nil)
        #expect(ProcessRow.formatCPU(.infinity) == nil)
        #expect(ProcessRow.formatCPU(-.infinity) == nil)
        #expect(ProcessRow.formatCPU(.greatestFiniteMagnitude) == nil)
    }

    // MARK: CPU time

    @Test("CPU time is formatted as hours, minutes and seconds")
    func cpuTimeFormatting() {
        #expect(ProcessRow.formatCPUTime(0) == "0:00:00")
        #expect(ProcessRow.formatCPUTime(83) == "0:01:23")
        #expect(ProcessRow.formatCPUTime(3_723) == "1:02:03")
        #expect(ProcessRow.formatCPUTime(360_000) == "100:00:00")
    }

    // MARK: Architecture

    @Test("architecture names the thing a reader cares about")
    func architectureNaming() {
        #expect(ProcessRow.formatArchitecture(.native) == "Native")
        #expect(ProcessRow.formatArchitecture(.translated) == "Rosetta")
    }

    // MARK: Construction from a snapshot

    @Test("a row carries the snapshot's values and the CPU usage keyed to its pid")
    func rowCarriesSnapshotValues() {
        let snapshot = ProcessSnapshot(
            pid: 501, parentPID: 1, name: "Xcode", userID: 501,
            memoryFootprintBytes: 2_000_000_000, cpuTimeSeconds: 42.0, threadCount: 30,
            diskBytesRead: 4096, diskBytesWritten: 8192, architecture: .native
        )
        let row = ProcessRow(snapshot: snapshot, cpuFraction: 1.5, userName: "george")

        #expect(row.id == 501)
        #expect(row.name == "Xcode")
        #expect(row.userName == "george")
        #expect(abs((row.cpuFraction ?? 0) - 1.5) < 1e-9)
        #expect(row.memoryBytes == 2_000_000_000)
        #expect(row.threadCount == 30)
    }

    @Test("a process with no CPU entry keeps a nil fraction rather than defaulting to zero")
    func missingCPUEntryStaysNil() {
        let snapshot = ProcessSnapshot(
            pid: 7, parentPID: 1, name: "kernel_task", userID: 0,
            memoryFootprintBytes: nil, cpuTimeSeconds: nil, threadCount: nil,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native
        )
        let row = ProcessRow(snapshot: snapshot, cpuFraction: nil, userName: "root")
        #expect(row.cpuFraction == nil)
        #expect(row.memoryBytes == nil)
    }
}
