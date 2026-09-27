import Darwin
import Foundation
import Testing
@testable import SystemMetrics

@Suite("Processes")
struct ProcessTests {

    private func snapshot(pid: pid_t, cpuTime: Double?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: 1, name: "test", userID: 501,
            memoryFootprintBytes: nil, cpuTimeSeconds: cpuTime, threadCount: nil,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native,
            startTimeSeconds: 1_700_000_000
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

    // MARK: Single-process reads

    /// A throwaway child this test owns outright. Every test that needs a live
    /// process spawns its own — nothing here ever touches a process it did
    /// not start.
    private static func spawnSleep() throws -> Foundation.Process {
        let child = Foundation.Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        return child
    }

    private static func reap(_ child: Foundation.Process) {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }

    /// The test that catches the two start-time conversions drifting apart.
    /// `ProcessIdentity` compares start times exactly, which is only sound if
    /// the sampler and the single-pid re-read run identical arithmetic.
    @Test("a single-pid identity read equals the identity the full sampler reports")
    func singlePidIdentityMatchesSampler() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        let sampled = try #require(
            ProcessSampler.snapshot().first { $0.pid == child.processIdentifier }
        )
        #expect(ProcessSampler.identity(of: child.processIdentifier) == sampled.identity)
    }

    @Test("there is no identity for a process that has exited")
    func noIdentityAfterExit() throws {
        let child = try Self.spawnSleep()
        let pid = child.processIdentifier
        let original = try #require(ProcessSampler.identity(of: pid))
        Self.reap(child)

        // Not `== nil`: a reused pid would give the exited process a fresh,
        // different identity rather than none, and `== nil` would flake.
        #expect(ProcessSampler.identity(of: pid) != original)
    }

    @Test("the executable path of a spawned sleep is /bin/sleep")
    func executablePathOfChild() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        #expect(ProcessSampler.executablePath(of: child.processIdentifier) == "/bin/sleep")
    }

    @Test("the sampler reads a real start time for the running process")
    func startTimeIsPopulatedForTheCurrentProcess() throws {
        // getpid() — the test runner itself — is always present in KERN_PROC_ALL
        // and readable (we own it), so its snapshot is a deterministic anchor.
        let mine = ProcessSampler.snapshot().first { $0.pid == getpid() }
        let startTime = try #require(mine).startTimeSeconds
        // A real Unix start time is on the order of 1.7e9; a stubbed or zeroed
        // field fails this, and it must not be in the future.
        #expect(startTime > 1_000_000_000)
        #expect(startTime <= Date().timeIntervalSince1970 + 1)
    }

    // MARK: Zombies

    /// A deterministic zombie: spawned with `posix_spawn` (not
    /// `Foundation.Process`, whose background reaper would collect it at an
    /// unpredictable moment), killed, and deliberately NOT reaped until the
    /// test ends. Returns once the kernel reports it as `SZOMB`.
    private static func makeZombie() throws -> pid_t {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
        defer { argv.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, nil) == 0)
        kill(pid, SIGKILL)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let process = ProcessSampler.kernelProcess(pid: pid), ProcessSampler.isZombie(process) {
                return pid
            }
            usleep(10_000)
        }
        Issue.record("child \(pid) never became a zombie")
        return pid
    }

    private static func reapZombie(_ pid: pid_t) {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// The cause of the old intermittent `footprintIsNeverZero` failure: a
    /// zombie's rusage reads back a zero footprint, which would be listed as
    /// "uses 0 bytes" — a value nobody measured.
    @Test("a zombie is not listed: it has exited, and its zeroed rusage is not a reading")
    func zombieIsNotListed() throws {
        let pid = try Self.makeZombie()
        defer { Self.reapZombie(pid) }

        #expect(!ProcessSampler.snapshot().contains { $0.pid == pid })
    }

    /// A zombie has no identity, so `ProcessControl`'s pre-signal re-check
    /// reports it as exited rather than "successfully" signalling a corpse.
    @Test("a zombie has no identity")
    func zombieHasNoIdentity() throws {
        let pid = try Self.makeZombie()
        defer { Self.reapZombie(pid) }

        #expect(ProcessSampler.identity(of: pid) == nil)
    }

    // MARK: stillAlive — snapshot()'s post-read filter, in isolation

    /// A hand-built `kinfo_proc` with only the fields `stillAlive` reads: pid,
    /// raw process state, and raw start time. Nothing here goes through a
    /// real sysctl — that is the point, so the filter can be driven by cases
    /// a live kernel won't reliably produce on demand.
    private func kinfoProcess(pid: pid_t, stat: Int32 = SRUN, startTime: timeval) -> kinfo_proc {
        var process = kinfo_proc()
        process.kp_proc.p_pid = pid
        process.kp_proc.p_stat = Int8(stat)
        process.kp_proc.p_starttime = startTime
        return process
    }

    /// Regression coverage for the filter itself: before this, `snapshot()`'s
    /// post-read re-check had no test that failed without it — the zombie
    /// tests above pass via `detail(for:)`'s earlier fast path regardless of
    /// what `stillAlive` does.
    @Test("stillAlive keeps a live, unchanged process")
    func stillAliveKeepsLiveUnchangedProcess() {
        let startTime = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        let enumerated = kinfoProcess(pid: 100, startTime: startTime)
        let after = kinfoProcess(pid: 100, startTime: startTime)

        let result = ProcessSampler.stillAlive(
            [(enumerated, snapshot(pid: 100, cpuTime: 1.0))], after: [after]
        )
        #expect(result.map(\.pid) == [100])
    }

    @Test("stillAlive drops a process that is a zombie in the post-read")
    func stillAliveDropsZombieInAfter() {
        let startTime = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        let enumerated = kinfoProcess(pid: 100, startTime: startTime)
        let after = kinfoProcess(pid: 100, stat: SZOMB, startTime: startTime)

        let result = ProcessSampler.stillAlive(
            [(enumerated, snapshot(pid: 100, cpuTime: 1.0))], after: [after]
        )
        #expect(result.isEmpty)
    }

    @Test("stillAlive drops a process missing from the post-read")
    func stillAliveDropsProcessMissingFromAfter() {
        let startTime = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        let enumerated = kinfoProcess(pid: 100, startTime: startTime)
        // `after` is non-empty but has no entry for pid 100 — it exited and a
        // different pid now occupies the table.
        let after = kinfoProcess(pid: 999, startTime: startTime)

        let result = ProcessSampler.stillAlive(
            [(enumerated, snapshot(pid: 100, cpuTime: 1.0))], after: [after]
        )
        #expect(result.isEmpty)
    }

    @Test("stillAlive drops a process whose start time differs by microseconds")
    func stillAliveDropsDifferingMicroseconds() {
        let enumerated = kinfoProcess(pid: 100, startTime: timeval(tv_sec: 1_700_000_000, tv_usec: 0))
        let after = kinfoProcess(pid: 100, startTime: timeval(tv_sec: 1_700_000_000, tv_usec: 1))

        let result = ProcessSampler.stillAlive(
            [(enumerated, snapshot(pid: 100, cpuTime: 1.0))], after: [after]
        )
        #expect(result.isEmpty)
    }

    @Test("stillAlive drops a process whose start time differs by seconds")
    func stillAliveDropsDifferingSeconds() {
        let enumerated = kinfoProcess(pid: 100, startTime: timeval(tv_sec: 1_700_000_000, tv_usec: 0))
        let after = kinfoProcess(pid: 100, startTime: timeval(tv_sec: 1_700_000_001, tv_usec: 0))

        let result = ProcessSampler.stillAlive(
            [(enumerated, snapshot(pid: 100, cpuTime: 1.0))], after: [after]
        )
        #expect(result.isEmpty)
    }

    @Test("stillAlive drops everything when the post-read itself is empty")
    func stillAliveWithEmptyAfterDropsEverything() {
        let startTime = timeval(tv_sec: 1_700_000_000, tv_usec: 0)
        let read = [
            (kinfoProcess(pid: 100, startTime: startTime), snapshot(pid: 100, cpuTime: 1.0)),
            (kinfoProcess(pid: 200, startTime: startTime), snapshot(pid: 200, cpuTime: 2.0)),
        ]

        // Never falls back to `read` unfiltered — a failed re-read sysctl
        // must not resurrect zeroed zombies.
        #expect(ProcessSampler.stillAlive(read, after: []).isEmpty)
    }
}
