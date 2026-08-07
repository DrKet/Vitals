import Foundation
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Process table")
struct ProcessTableTests {

    private func row(_ pid: pid_t, name: String = "p", cpu: Double? = 0, memory: UInt64? = 0) -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: "u", cpuFraction: cpu, memoryBytes: memory,
            threadCount: nil, cpuTimeSeconds: nil, diskReadBytes: nil,
            diskWrittenBytes: nil, architecture: .native, startTimeSeconds: 1_700_000_000
        )
    }

    private func row(_ pid: pid_t, startTime: Double, name: String = "p") -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: "u", cpuFraction: 0, memoryBytes: 0,
            threadCount: nil, cpuTimeSeconds: nil, diskReadBytes: nil,
            diskWrittenBytes: nil, architecture: .native, startTimeSeconds: startTime
        )
    }

    // MARK: Building rows

    @Test("a process with no CPU entry becomes a row with a nil fraction, not zero")
    func missingCPUEntryBecomesNil() {
        let snapshot = ProcessSnapshot(
            pid: 9, parentPID: 1, name: "syslogd", userID: 0,
            memoryFootprintBytes: 1000, cpuTimeSeconds: nil, threadCount: 2,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native,
            startTimeSeconds: 1_700_000_000
        )
        let sample = ProcessSeriesSample(processes: [snapshot], cpuUsage: [:])
        let rows = ProcessTable.rows(from: sample, resolver: UserNameResolver())

        #expect(rows.count == 1)
        #expect(rows[0].cpuFraction == nil)
        #expect(rows[0].userName == "root")
    }

    // MARK: Filtering

    @Test("filtering matches a name substring, ignoring case")
    func filterMatchesNameSubstring() {
        let rows = [row(1, name: "Xcode"), row(2, name: "WindowServer"), row(3, name: "finder")]
        #expect(ProcessTable.filtered(rows, query: "wind").map(\.pid) == [2])
        #expect(ProcessTable.filtered(rows, query: "XCODE").map(\.pid) == [1])
    }

    @Test("a numeric query also matches an exact pid")
    func filterMatchesExactPID() {
        let rows = [row(42, name: "Xcode"), row(7, name: "finder")]
        #expect(ProcessTable.filtered(rows, query: "42").map(\.pid) == [42])
    }

    @Test("an empty query returns every row untouched")
    func emptyQueryReturnsEverything() {
        let rows = [row(1), row(2)]
        #expect(ProcessTable.filtered(rows, query: "").count == 2)
        #expect(ProcessTable.filtered(rows, query: "   ").count == 2)
    }

    @Test("a query matching nothing returns nothing, which is distinct from having no data")
    func nonMatchingQueryReturnsEmpty() {
        #expect(ProcessTable.filtered([row(1, name: "Xcode")], query: "zzz").isEmpty)
    }

    // MARK: Order holding

    @Test("rows keep the established order even when their values change")
    func establishedOrderIsKept() {
        // The heart of "values update, order holds": pid 3 becoming the
        // heaviest must not move it while the user is reading.
        let ordered = ProcessTable.ordered([row(3, cpu: 9.0), row(1, cpu: 0.1)], keeping: [1, 3])
        #expect(ordered.map(\.pid) == [1, 3])
    }

    @Test("a process that exits leaves its slot rather than shifting everything")
    func exitedProcessIsDropped() {
        // Input order is deliberately not the expected output order (3 before 1),
        // so an identity passthrough of `rows` would wrongly yield [3, 1]. This
        // proves the established order [1, 2, 3] is actually applied and pid 2
        // (absent from `rows`) is actually dropped, rather than merely not invented.
        let ordered = ProcessTable.ordered([row(3), row(1)], keeping: [1, 2, 3])
        #expect(ordered.map(\.pid) == [1, 3])
    }

    @Test("a newly started process is appended, not inserted mid-table")
    func newProcessIsAppended() {
        // pid 99 (not in the established order) leads the input; an identity
        // passthrough would wrongly yield [99, 1, 2]. This proves 99 is actually
        // moved to the end rather than left wherever it happened to appear.
        let ordered = ProcessTable.ordered([row(99), row(1), row(2)], keeping: [1, 2])
        #expect(ordered.map(\.pid) == [1, 2, 99])
    }

    @Test("with no established order the rows are returned as given")
    func emptyOrderReturnsInputOrder() {
        #expect(ProcessTable.ordered([row(5), row(2)], keeping: []).map(\.pid) == [5, 2])
    }

    @Test("a pid repeated in the established order is placed once, not duplicated")
    func repeatedPIDInOrderIsPlacedOnce() {
        // `order` is meant to hold each displayed pid at most once; a repeat
        // (however it got there) must not hand `Table` two rows sharing one
        // `Identifiable` id. Without the dedup, this would wrongly yield
        // [1, 1, 2].
        let ordered = ProcessTable.ordered([row(1), row(2)], keeping: [1, 1, 2])
        #expect(ordered.map(\.pid) == [1, 2])
    }

    // MARK: Heat map

    @Test("the largest value in a column is fully saturated and the rest are proportional")
    func heatScalesToTheColumnMaximum() {
        let rows = [row(1, cpu: 1.0), row(2, cpu: 4.0)]
        let maximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        #expect(abs((maximum ?? 0) - 4.0) < 1e-9)
        #expect(abs((ProcessTable.heatFraction(4.0, maximum: maximum) ?? 0) - 1.0) < 1e-9)
        #expect(abs((ProcessTable.heatFraction(1.0, maximum: maximum) ?? 0) - 0.25) < 1e-9)
    }

    @Test("an unreadable value gets no shading, because absence is not a low value")
    func unreadableValueHasNoShade() {
        #expect(ProcessTable.heatFraction(nil, maximum: 4.0) == nil)

        // The contrast this test's name claims: a READABLE value at the same
        // maximum does shade — proportionally, not just "non-nil". Without
        // this, a `heatFraction` degenerated to `return value` (ignoring
        // `maximum` entirely) would still pass: its only other probe here is
        // `nil`, which round-trips through such a stub unnoticed.
        #expect(abs((ProcessTable.heatFraction(4.0, maximum: 4.0) ?? -1) - 1.0) < 1e-9)
    }

    @Test("a column where nothing is readable has no maximum and shades nothing")
    func allUnknownColumnHasNoMaximum() {
        let rows = [row(1, cpu: nil), row(2, cpu: nil)]
        #expect(ProcessTable.maximum(of: \.cpuFraction, in: rows) == nil)
        #expect(ProcessTable.heatFraction(nil, maximum: nil) == nil)
        #expect(ProcessTable.heatFraction(1.0, maximum: nil) == nil)
    }

    @Test("an all-zero column shades nothing rather than dividing by zero")
    func zeroMaximumShadesNothing() {
        #expect(ProcessTable.heatFraction(0, maximum: 0) == nil)
    }

    @Test("a single row is fully saturated, since it is its own maximum")
    func singleRowIsItsOwnMaximum() {
        let rows = [row(1, cpu: 0.02)]
        let maximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        #expect(abs((ProcessTable.heatFraction(0.02, maximum: maximum) ?? 0) - 1.0) < 1e-9)
    }

    // MARK: validSelection

    @Test("a selection whose row is still present is preserved")
    func presentSelectionIsPreserved() {
        let rows = [row(100, startTime: 1_700_000_000), row(200, startTime: 1_700_000_500)]
        let selection = ProcessIdentity(pid: 100, startTimeSeconds: 1_700_000_000)
        #expect(ProcessTable.validSelection(selection, in: rows) == selection)
    }

    @Test("a recycled pid — same pid, different start time — is NOT preserved")
    func recycledPidIsNotPreserved() {
        // The weight-bearing case. pid 100 is still in the list, but it is a
        // DIFFERENT process (a later start time), so the old selection must
        // not silently transfer to it.
        let rows = [row(100, startTime: 1_700_009_999)]
        let selection = ProcessIdentity(pid: 100, startTimeSeconds: 1_700_000_000)
        #expect(ProcessTable.validSelection(selection, in: rows) == nil)
    }

    @Test("a selection whose pid is gone entirely becomes nil")
    func absentPidBecomesNil() {
        let rows = [row(200, startTime: 1_700_000_500)]
        let selection = ProcessIdentity(pid: 100, startTimeSeconds: 1_700_000_000)
        #expect(ProcessTable.validSelection(selection, in: rows) == nil)
    }

    @Test("a nil selection stays nil")
    func nilSelectionStaysNil() {
        let rows = [row(100, startTime: 1_700_000_000)]
        #expect(ProcessTable.validSelection(nil, in: rows) == nil)
    }
}
