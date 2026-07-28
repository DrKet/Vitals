import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Processes page")
struct ProcessesPageTests {

    private static func snapshot(_ pid: pid_t, _ name: String, cpuTime: Double?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: 1, name: name, userID: 501,
            memoryFootprintBytes: UInt64(pid) * 1_000_000, cpuTimeSeconds: cpuTime,
            threadCount: 3, diskBytesRead: 512, diskBytesWritten: 256,
            architecture: .native
        )
    }

    private func storeWithProcesses() async throws -> MetricsStore {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let sample = ProcessSeriesSample(
            processes: [
                Self.snapshot(1, "launchd", cpuTime: 12),
                Self.snapshot(42, "Xcode", cpuTime: 900),
                Self.snapshot(77, "kernel_task", cpuTime: nil),
            ],
            cpuUsage: [1: 0.02, 42: 3.5]      // 77 deliberately unreadable
        )
        await engine.register(AnySampler { sample }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)
        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()
        return store
    }

    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFromLiveStore() async throws {
        let store = try await storeWithProcesses()
        let rendered = try renderPNG(
            ProcessesPage(store: store),
            size: CGSize(width: 900, height: 600),
            named: "processes-page-with-data"
        )
        #expect(rendered.url.isFileURL)
    }

    @Test("renders without trapping when no listing has arrived yet")
    func rendersEmptyStore() throws {
        let store = MetricsStore(
            engine: MetricsEngine(intervalOverride: .milliseconds(5)),
            profile: nil
        )
        let rendered = try renderPNG(
            ProcessesPage(store: store),
            size: CGSize(width: 900, height: 600),
            named: "processes-page-empty-store"
        )
        #expect(rendered.url.isFileURL)
    }

    @Test("the default sort is CPU descending, so the heaviest process is first")
    func defaultSortIsCPUDescending() async throws {
        let store = try await storeWithProcesses()
        let sample = try #require(store.processes)
        let rows = ProcessTable.rows(from: sample, resolver: UserNameResolver())
            .sorted(using: ProcessComparator(field: .cpu, order: .reverse))

        // Xcode heaviest, launchd next, kernel_task last because unreadable.
        #expect(rows.map(\.name) == ["Xcode", "launchd", "kernel_task"])
    }

    // MARK: Header key path -> sort field mapping

    /// `resort()` only ever reads `.keyPath` and `.order` off the bound
    /// `KeyPathComparator` — the actual ordering always goes through
    /// `ProcessComparator`. That makes this mapping table the single point of
    /// truth for which header a click on "Memory," "Threads," "Disk Write"
    /// etc. actually sorts by. `defaultSortIsCPUDescending` only exercises the
    /// `.cpu` branch; a swapped case here (e.g. diskRead/diskWrite) would
    /// silently sort the wrong column and nothing else would catch it.
    @Test("each sortable column's key path maps back to its own field, not a neighbour's")
    func keyPathMapsToExpectedField() {
        #expect(ProcessesPage.field(for: \ProcessRow.name) == .name)
        #expect(ProcessesPage.field(for: \ProcessRow.cpuFractionKey) == .cpu)
        #expect(ProcessesPage.field(for: \ProcessRow.memoryBytesKey) == .memory)
        #expect(ProcessesPage.field(for: \ProcessRow.pid) == .pid)
        #expect(ProcessesPage.field(for: \ProcessRow.userName) == .user)
        #expect(ProcessesPage.field(for: \ProcessRow.threadCountKey) == .threads)
        #expect(ProcessesPage.field(for: \ProcessRow.cpuTimeSecondsKey) == .cpuTime)
        #expect(ProcessesPage.field(for: \ProcessRow.diskReadBytesKey) == .diskRead)
        #expect(ProcessesPage.field(for: \ProcessRow.diskWrittenBytesKey) == .diskWrite)
    }

    @Test("an unrecognised key path yields nil, which resort() falls back to CPU for")
    func unrecognisedKeyPathYieldsNil() {
        // The Architecture column deliberately binds `\.name` rather than a
        // key path of its own (`ProcessArchitecture` is not `Comparable`), so
        // it is not a genuine "unrecognised" case. A raw, un-keyed property
        // like `\.cpuFraction` (as opposed to its `.cpuFractionKey` wrapper)
        // is never produced by any column and stands in for one here.
        #expect(ProcessesPage.field(for: \ProcessRow.cpuFraction) == nil)
    }
}
