import Foundation
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process sort")
struct ProcessSortTests {

    private func row(_ pid: pid_t, cpu: Double?, memory: UInt64? = 0, name: String = "p") -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: "u", cpuFraction: cpu,
            memoryBytes: memory, threadCount: nil, cpuTimeSeconds: nil,
            diskReadBytes: nil, diskWrittenBytes: nil, architecture: .native
        )
    }

    @Test("descending CPU puts the heaviest first and the unreadable last")
    func descendingPutsUnknownsLast() {
        let rows = [row(1, cpu: 0.1), row(2, cpu: nil), row(3, cpu: 2.0)]
        let sorted = rows.sorted(using: ProcessComparator(field: .cpu, order: .reverse))
        #expect(sorted.map(\.pid) == [3, 1, 2])
    }

    @Test("ascending CPU puts the lightest first and STILL puts the unreadable last")
    func ascendingAlsoPutsUnknownsLast() {
        // The point of the whole design. Flipping the sort must not promote
        // unreadable processes to the top as though they were the idlest —
        // that would assert something we did not measure.
        let rows = [row(1, cpu: 0.1), row(2, cpu: nil), row(3, cpu: 2.0)]
        let sorted = rows.sorted(using: ProcessComparator(field: .cpu, order: .forward))
        #expect(sorted.map(\.pid) == [1, 3, 2])
    }

    @Test("an unreadable value does not tie with a genuine zero")
    func unknownIsNotZero() {
        let rows = [row(1, cpu: nil), row(2, cpu: 0.0)]
        let sorted = rows.sorted(using: ProcessComparator(field: .cpu, order: .forward))
        #expect(sorted.map(\.pid) == [2, 1])
    }

    @Test("two unreadable values compare as equal, so their relative order is stable")
    func unknownsTieWithEachOther() {
        let comparator = ProcessComparator(field: .cpu, order: .forward)
        #expect(comparator.compare(row(1, cpu: nil), row(2, cpu: nil)) == .orderedSame)
    }

    @Test("memory sorts by value with unreadable last, in both directions")
    func memorySortsWithUnknownsLast() {
        let rows = [row(1, cpu: 0, memory: 500), row(2, cpu: 0, memory: nil), row(3, cpu: 0, memory: 9_000)]
        #expect(rows.sorted(using: ProcessComparator(field: .memory, order: .reverse)).map(\.pid) == [3, 1, 2])
        #expect(rows.sorted(using: ProcessComparator(field: .memory, order: .forward)).map(\.pid) == [1, 3, 2])
    }

    @Test("name sorts case-insensitively so Xcode does not outrank finder")
    func nameSortsCaseInsensitively() {
        let rows = [row(1, cpu: 0, name: "Xcode"), row(2, cpu: 0, name: "finder")]
        let sorted = rows.sorted(using: ProcessComparator(field: .name, order: .forward))
        #expect(sorted.map(\.name) == ["finder", "Xcode"])
    }

    @Test("pid is never absent, so it sorts plainly in both directions")
    func pidSortsPlainly() {
        let rows = [row(30, cpu: nil), row(2, cpu: nil), row(11, cpu: nil)]
        #expect(rows.sorted(using: ProcessComparator(field: .pid, order: .forward)).map(\.pid) == [2, 11, 30])
        #expect(rows.sorted(using: ProcessComparator(field: .pid, order: .reverse)).map(\.pid) == [30, 11, 2])
    }
}
