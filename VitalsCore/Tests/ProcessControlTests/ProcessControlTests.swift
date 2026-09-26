import Darwin
import Foundation
import ProcessControl
import SystemMetrics
import Testing

/// Every test here signals only a `/bin/sleep` it spawned itself. The one
/// exception targets pid 1 to prove EPERM handling, and is disabled when
/// running as root — where it would really signal launchd.
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
    func staleIdentityIsRefused() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        let real = try Self.identity(of: child)
        let stale = ProcessIdentity(pid: real.pid, startTimeSeconds: real.startTimeSeconds + 1)

        #expect(throws: ProcessControlError.exited) {
            try ProcessControl.perform(.forceQuit, on: stale)
        }
        // Not `child.isRunning`: Foundation.Process's isRunning updates
        // asynchronously and can still read true (or go stale) right after
        // the call returns. Ask the kernel directly instead.
        #expect(ProcessSampler.identity(of: real.pid) == real)
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

    @Test("signalling another user's process reports not permitted",
          .enabled(if: getuid() != 0, "as root this would really signal launchd"))
    func otherUsersProcessIsNotPermitted() throws {
        let launchd = try #require(ProcessSampler.identity(of: 1))

        #expect(throws: ProcessControlError.notPermitted) {
            try ProcessControl.perform(.quit, on: launchd)
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
