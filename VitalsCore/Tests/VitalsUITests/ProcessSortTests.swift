import Foundation
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process sort")
struct ProcessSortTests {

    private func row(
        _ pid: pid_t,
        cpu: Double?,
        memory: UInt64? = 0,
        name: String = "p",
        user: String = "u",
        threads: Int? = nil,
        cpuTime: Double? = nil,
        diskRead: UInt64? = nil,
        diskWrite: UInt64? = nil,
        architecture: ProcessArchitecture = .native
    ) -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: user, userID: 501, cpuFraction: cpu,
            memoryBytes: memory, threadCount: threads, cpuTimeSeconds: cpuTime,
            diskReadBytes: diskRead, diskWrittenBytes: diskWrite, architecture: architecture,
            startTimeSeconds: 1_700_000_000
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

    @Test("user sorts case-insensitively and independently of name, in both directions")
    func userSortsCaseInsensitively() {
        // Names are deliberately in the OPPOSITE order from user names, so a
        // comparator that accidentally read `.name` instead of `.userName`
        // would produce the reversed result and fail this test.
        let rows = [
            row(1, cpu: 0, name: "a", user: "Zeus"),
            row(2, cpu: 0, name: "z", user: "adam")
        ]
        // Case-sensitive ASCII compare would put "Zeus" (capital Z) ahead of
        // "adam", since 'Z' < 'a' in ASCII. Case-insensitive compare puts
        // "adam" first. This is the behavior localizedCaseInsensitiveCompare
        // is relied on for.
        #expect(rows.sorted(using: ProcessComparator(field: .user, order: .forward)).map(\.pid) == [2, 1])
        #expect(rows.sorted(using: ProcessComparator(field: .user, order: .reverse)).map(\.pid) == [1, 2])
    }

    @Test("architecture sorts Native before Rosetta, independently of name, in both directions")
    func architectureSortsIndependentlyOfName() {
        // Name/user are deliberately in the OPPOSITE order from architecture,
        // so a comparator that accidentally read `.name`/`.userName` instead
        // of `.architecture` would produce the reversed result.
        let rows = [
            row(1, cpu: 0, name: "a", user: "a", architecture: .translated),
            row(2, cpu: 0, name: "z", user: "z", architecture: .native)
        ]
        #expect(rows.sorted(using: ProcessComparator(field: .architecture, order: .forward)).map(\.pid) == [2, 1])
        #expect(rows.sorted(using: ProcessComparator(field: .architecture, order: .reverse)).map(\.pid) == [1, 2])
    }

    @Test("threads sorts by count with unreadable last, in both directions")
    func threadsSortsWithUnknownsLast() {
        // cpuTime/diskRead/diskWrite are all fully-populated (no nil) and
        // monotonic, so if `.threads` were wired to any of them instead, the
        // nil-last group would vanish and the order would change.
        let rows = [
            row(1, cpu: 0, threads: 4, cpuTime: 500, diskRead: 5_000, diskWrite: 50_000),
            row(2, cpu: 0, threads: nil, cpuTime: 600, diskRead: 6_000, diskWrite: 60_000),
            row(3, cpu: 0, threads: 12, cpuTime: 700, diskRead: 7_000, diskWrite: 70_000)
        ]
        #expect(rows.sorted(using: ProcessComparator(field: .threads, order: .reverse)).map(\.pid) == [3, 1, 2])
        #expect(rows.sorted(using: ProcessComparator(field: .threads, order: .forward)).map(\.pid) == [1, 3, 2])
    }

    @Test("cpuTime sorts by accumulated seconds with unreadable last, in both directions")
    func cpuTimeSortsWithUnknownsLast() {
        // threads is fully-populated and inversely ordered relative to
        // cpuTime, so a swap with `.threads` would both drop the nil-last
        // group and reverse the readable order.
        let rows = [
            row(1, cpu: 0, threads: 40, cpuTime: 12.5),
            row(2, cpu: 0, threads: 30, cpuTime: nil),
            row(3, cpu: 0, threads: 20, cpuTime: 99.25)
        ]
        #expect(rows.sorted(using: ProcessComparator(field: .cpuTime, order: .reverse)).map(\.pid) == [3, 1, 2])
        #expect(rows.sorted(using: ProcessComparator(field: .cpuTime, order: .forward)).map(\.pid) == [1, 3, 2])
    }

    @Test("diskRead sorts by bytes read with unreadable last, in both directions")
    func diskReadSortsWithUnknownsLast() {
        // diskWrite values are deliberately inverted relative to diskRead
        // (and never nil), so swapping `.diskRead` to read diskWrittenBytes
        // would both drop the nil-last group and reverse the readable order.
        let rows = [
            row(1, cpu: 0, diskRead: 500, diskWrite: 9_000),
            row(2, cpu: 0, diskRead: nil, diskWrite: 8_000),
            row(3, cpu: 0, diskRead: 9_000, diskWrite: 500)
        ]
        #expect(rows.sorted(using: ProcessComparator(field: .diskRead, order: .reverse)).map(\.pid) == [3, 1, 2])
        #expect(rows.sorted(using: ProcessComparator(field: .diskRead, order: .forward)).map(\.pid) == [1, 3, 2])
    }

    @Test("diskWrite sorts by bytes written with unreadable last, in both directions")
    func diskWriteSortsWithUnknownsLast() {
        // diskRead values are deliberately inverted relative to diskWrite
        // (and never nil), so swapping `.diskWrite` to read diskReadBytes
        // would both drop the nil-last group and reverse the readable order.
        let rows = [
            row(1, cpu: 0, diskRead: 9_000, diskWrite: 500),
            row(2, cpu: 0, diskRead: 8_000, diskWrite: nil),
            row(3, cpu: 0, diskRead: 500, diskWrite: 9_000)
        ]
        #expect(rows.sorted(using: ProcessComparator(field: .diskWrite, order: .reverse)).map(\.pid) == [3, 1, 2])
        #expect(rows.sorted(using: ProcessComparator(field: .diskWrite, order: .forward)).map(\.pid) == [1, 3, 2])
    }
}
