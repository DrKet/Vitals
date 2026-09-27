import Darwin
import Foundation
import ProcessControl
import SystemMetrics
import Testing

/// Every test here signals only a `/bin/sleep` it spawned itself. The one
/// exception targets a root daemon to prove EPERM handling, and is disabled
/// when running as root — where it would really kill it. (The pid 0 and pid 1
/// tests are refused before `kill` runs, so they are safe as any user.)
@MainActor
@Suite("Process control")
struct ProcessControlTests {

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

    private static func identity(of child: Foundation.Process) throws -> ProcessIdentity {
        try #require(ProcessSampler.identity(of: child.processIdentifier))
    }

    @Test("Quit ends a non-app process with SIGTERM")
    func quitSendsSIGTERM() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        try ProcessControl.perform(.quit, on: Self.identity(of: child))
        child.waitUntilExit()

        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test("Force Quit ends a process with SIGKILL")
    func forceQuitSendsSIGKILL() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        try ProcessControl.perform(.forceQuit, on: Self.identity(of: child))
        child.waitUntilExit()

        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGKILL)
    }

    /// The safety test. A pid that now belongs to a different process looks
    /// exactly like this: right pid, wrong start time. The action must be
    /// refused and the process must survive it.
    @Test("a right pid with the wrong start time is refused and the process survives")
    func staleIdentityIsRefused() async throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        let real = try Self.identity(of: child)
        let stale = ProcessIdentity(pid: real.pid, startTimeSeconds: real.startTimeSeconds + 1)

        #expect(throws: ProcessControlError.exited) {
            try ProcessControl.perform(.forceQuit, on: stale)
        }
        // Not `child.isRunning`: Foundation.Process updates it asynchronously.
        //
        // kill(2) returns before the target has exited, so one read straight
        // after `perform` could still see a wrongly-killed child alive. Watch
        // it for a while: SIGKILL takes effect well within this window, and a
        // killed child stops matching (a zombie has no identity).
        // `Task.sleep`, not `usleep`: this suite is on the main actor, and a
        // blocking sleep would hold it for the whole window, starving every
        // other main-actor test running in parallel.
        for _ in 0..<25 {
            #expect(ProcessSampler.identity(of: real.pid) == real)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a process that has already exited reports exited")
    func exitedProcessReportsExited() throws {
        let child = try Self.spawnSleep()
        let identity = try Self.identity(of: child)
        Self.reap(child)

        #expect(throws: ProcessControlError.exited) {
            try ProcessControl.perform(.quit, on: identity)
        }
    }

    /// Targets a core root daemon (not pid 1, which is refused before `kill`
    /// ever runs). Named rather than "any root process": an on-demand launchd
    /// job could exit between the snapshot and the call and report `.exited`
    /// instead; these three run for the whole session. Force Quit, so the path
    /// is a bare `kill` with no `NSRunningApplication` lookup in between.
    @Test("signalling another user's process reports not permitted",
          .enabled(if: getuid() != 0, "as root this would really kill a system daemon"))
    func otherUsersProcessIsNotPermitted() throws {
        let coreDaemons: Set<String> = ["logd", "configd", "notifyd"]
        let rootDaemon = try #require(
            ProcessSampler.snapshot().first { $0.userID == 0 && coreDaemons.contains($0.name) }
        )

        #expect(throws: ProcessControlError.notPermitted) {
            try ProcessControl.perform(.forceQuit, on: rootDaemon.identity)
        }
    }

    /// Policy, not permissions: refused before `kill`, so this is safe to run
    /// as any user — including root, where the kernel would otherwise allow it.
    @Test("pid 1 (launchd) is refused before anything is signalled")
    func pidOneIsRefused() throws {
        let launchd = try #require(ProcessSampler.identity(of: 1))
        #expect(throws: ProcessControlError.systemCritical) {
            try ProcessControl.perform(.forceQuit, on: launchd)
        }
    }

    @Test("pid 0 is refused before anything is signalled")
    func pidZeroIsRefused() throws {
        let kernelTask = try #require(ProcessSampler.identity(of: 0))
        #expect(throws: ProcessControlError.notSignallable) {
            try ProcessControl.perform(.forceQuit, on: kernelTask)
        }
    }
}
