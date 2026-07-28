import Darwin
import Testing
@testable import SystemMetrics

@Suite("Processes")
struct ProcessTests {

    private func snapshot(pid: pid_t, cpuTime: Double?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: 1, name: "test", userID: 501,
            memoryFootprintBytes: nil, cpuTimeSeconds: cpuTime, threadCount: nil,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native
        )
    }

    @Test("first update produces no CPU percentage")
    func firstUpdateProducesNothing() {
        var tracker = ProcessCPUTracker()
        #expect(tracker.update([snapshot(pid: 100, cpuTime: 5.0)], at: 10.0).isEmpty)
    }

    @Test("CPU percentage is consumed CPU time over elapsed wall time")
    func computesPercentage() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 5.0)], at: 10.0)
        // Consumed 1s of CPU across 2s of wall time on one core: 50%.
        let usage = tracker.update([snapshot(pid: 100, cpuTime: 6.0)], at: 12.0)
        #expect(usage[100] == 0.5)
    }

    @Test("a process may exceed 100% by using multiple cores")
    func exceedsOneHundredPercent() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 0)], at: 10.0)
        // 4s of CPU time in 1s of wall time: four cores saturated.
        let usage = tracker.update([snapshot(pid: 100, cpuTime: 4.0)], at: 11.0)
        #expect(usage[100] == 4.0)
    }

    @Test("a new process produces no percentage on its first appearance")
    func newProcessHasNoPercentage() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 0)], at: 10.0)
        let usage = tracker.update(
            [snapshot(pid: 100, cpuTime: 1.0), snapshot(pid: 200, cpuTime: 50.0)], at: 11.0
        )
        #expect(usage[100] == 1.0)
        #expect(usage[200] == nil)
    }

    @Test("a recycled PID with decreasing CPU time is dropped")
    func recycledPIDDropped() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 500.0)], at: 10.0)
        let usage = tracker.update([snapshot(pid: 100, cpuTime: 0.2)], at: 11.0)
        #expect(usage[100] == nil)
    }

    @Test("exited processes are forgotten so a reused PID starts fresh")
    func exitedProcessesForgotten() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 500.0)], at: 10.0)
        _ = tracker.update([], at: 11.0)
        let usage = tracker.update([snapshot(pid: 100, cpuTime: 1.0)], at: 12.0)
        #expect(usage[100] == nil)
    }

    @Test("live snapshot includes this test process with a real footprint")
    func liveSnapshotIncludesSelf() throws {
        let processes = ProcessSampler.snapshot()
        let selfPID = getpid()
        let me = try #require(processes.first { $0.pid == selfPID })

        #expect(try #require(me.memoryFootprintBytes) > 1_000_000)
        #expect(try #require(me.cpuTimeSeconds) > 0)
        #expect(try #require(me.threadCount) > 0)
    }

    @Test("a footprint is either a real value or nil, never zero")
    func footprintIsNeverZero() {
        // Zero would mean "we failed to read it" masquerading as "uses no
        // memory". Failed reads must be nil.
        #expect(ProcessSampler.snapshot().allSatisfy { $0.memoryFootprintBytes != 0 })
    }

    @Test("CPU time is either a real value or nil, never zero")
    func cpuTimeIsNeverZero() {
        // Zero would mean "we couldn't read it" masquerading as "genuinely
        // idle". Permission-denied reads must be nil, not zero.
        #expect(ProcessSampler.snapshot().allSatisfy { $0.cpuTimeSeconds != 0 })
    }

    @Test("a process with unreadable CPU time is absent from the tracker's result")
    func unreadableCPUTimeExcludedFromResult() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 5.0)], at: 10.0)
        let usage = tracker.update(
            [snapshot(pid: 100, cpuTime: nil), snapshot(pid: 200, cpuTime: nil)], at: 11.0
        )
        #expect(usage[100] == nil)
        #expect(usage[200] == nil)
        #expect(usage.isEmpty)
    }

    @Test("a PID that becomes readable again after nil starts fresh, not against the stale sample")
    func recoversAfterNilWithoutStaleDelta() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([snapshot(pid: 100, cpuTime: 5.0)], at: 10.0)
        _ = tracker.update([snapshot(pid: 100, cpuTime: nil)], at: 11.0)

        // First readable sample after the gap — no percentage, same as a new PID.
        let resumed = tracker.update([snapshot(pid: 100, cpuTime: 50.0)], at: 12.0)
        #expect(resumed[100] == nil)

        // Next tick can now compute a real delta against the post-gap baseline.
        let usage = tracker.update([snapshot(pid: 100, cpuTime: 51.0)], at: 13.0)
        #expect(usage[100] == 1.0)
    }

    @Test("live snapshot includes launchd as PID 1")
    func liveSnapshotIncludesLaunchd() throws {
        let processes = ProcessSampler.snapshot()
        let launchd = try #require(processes.first { $0.pid == 1 })
        #expect(launchd.name == "launchd")
        #expect(launchd.userID == 0)
    }

    @Test("live snapshot sees processes owned by other users")
    func liveSnapshotSeesOtherUsers() {
        let processes = ProcessSampler.snapshot()
        #expect(processes.count > 50)
        #expect(processes.contains { $0.userID == 0 })
    }
}
