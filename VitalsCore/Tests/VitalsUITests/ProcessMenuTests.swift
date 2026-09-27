import Darwin
import Foundation
import ProcessControl
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process menu")
struct ProcessMenuTests {

    private static let me: uid_t = 501
    private static let vitalsPID: pid_t = 4242

    private func row(pid: pid_t, userID: uid_t) -> ProcessRow {
        ProcessRow(
            pid: pid, name: "p", userName: "u", userID: userID, cpuFraction: nil,
            memoryBytes: nil, threadCount: nil, cpuTimeSeconds: nil, diskReadBytes: nil,
            diskWrittenBytes: nil, architecture: .native, startTimeSeconds: 1_700_000_000
        )
    }

    private func state(pid: pid_t, userID: uid_t, path: String? = "/bin/sleep") -> ProcessMenuState {
        ProcessMenu.state(
            for: row(pid: pid, userID: userID),
            currentUserID: Self.me, ownPID: Self.vitalsPID, executablePath: path
        )
    }

    // MARK: Rules

    @Test("your own ordinary process can be quit")
    func ownProcessIsQuittable() {
        #expect(state(pid: 900, userID: Self.me).quitUnavailable == nil)
    }

    @Test("another user's process needs administrator access")
    func otherUserNeedsAdministrator() {
        #expect(state(pid: 900, userID: 502).quitUnavailable == .needsAdministrator)
    }

    @Test("a root process needs administrator access")
    func rootNeedsAdministrator() {
        #expect(state(pid: 900, userID: 0).quitUnavailable == .needsAdministrator)
    }

    /// pid 1 is root-owned, but "needs administrator access" would be false:
    /// root cannot usefully quit launchd either. System-critical wins.
    @Test("kernel_task and launchd are system-critical, not merely root's")
    func systemCriticalBeatsOwnership() {
        #expect(state(pid: 0, userID: 0).quitUnavailable == .systemCritical)
        #expect(state(pid: 1, userID: 0).quitUnavailable == .systemCritical)
    }

    @Test("Vitals cannot quit itself from its own table")
    func vitalsItselfIsExcluded() {
        #expect(state(pid: Self.vitalsPID, userID: Self.me).quitUnavailable == .isVitals)
    }

    @Test("Reveal in Finder is available exactly when the path is readable")
    func revealFollowsPath() {
        #expect(state(pid: 900, userID: Self.me, path: "/bin/sleep").canReveal)
        #expect(!state(pid: 900, userID: Self.me, path: nil).canReveal)
    }

    // MARK: Strings

    @Test("each unavailable reason explains itself")
    func reasonsExplainThemselves() {
        #expect(QuitUnavailableReason.systemCritical.explanation == "System process — can’t be quit")
        #expect(QuitUnavailableReason.isVitals.explanation == "Quit Vitals from its app menu")
        #expect(QuitUnavailableReason.needsAdministrator.explanation
                == "Quitting this process needs administrator access")
    }

    @Test("the confirmation names the process and its pid")
    func confirmationNamesProcess() {
        #expect(ProcessMenu.confirmationMessage(name: "sleep", pid: 4312)
                == "“sleep” (PID 4312). Force Quit stops it immediately; unsaved changes may be lost.")
    }

    @Test("each failure says why, in words")
    func failureMessages() {
        #expect(ProcessMenu.failureMessage(.exited, name: "sleep")
                == "“sleep” couldn’t be quit because it has already exited.")
        #expect(ProcessMenu.failureMessage(.notPermitted, name: "sleep")
                == "“sleep” couldn’t be quit because you don’t have permission.")
        #expect(ProcessMenu.failureMessage(.notSignallable, name: "kernel_task")
                == "“kernel_task” is a system process and can’t be quit.")
        #expect(ProcessMenu.failureMessage(.quitRequestNotSent, name: "Safari")
                == "“Safari” couldn’t be asked to quit. Try Force Quit.")
        #expect(ProcessMenu.failureMessage(.failed(errno: EINVAL), name: "sleep")
                == "“sleep” couldn’t be quit: \(String(cString: strerror(EINVAL))).")
    }
}
