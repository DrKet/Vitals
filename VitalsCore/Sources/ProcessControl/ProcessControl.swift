import AppKit
import Darwin
import SystemMetrics

public enum ProcessAction: Sendable, Equatable {
    /// A polite request: ⌘Q's Apple event for a GUI app, `SIGTERM` otherwise.
    case quit
    /// `SIGKILL`. Cannot be caught; unsaved work is lost.
    case forceQuit
}

public enum ProcessControlError: Error, Equatable, Sendable {
    /// The process is gone, or its pid now belongs to a different process.
    case exited
    /// `EPERM` — the process is not ours to signal.
    case notPermitted
    /// A pid `kill(2)` would not read as one process: 0 means "every process
    /// in the caller's own process group" (so signalling `kernel_task` would
    /// hit Vitals itself), and a negative pid means a whole process group —
    /// `-1` is every process the user owns. Refused before any identity check
    /// or signal.
    case notSignallable
    /// `NSRunningApplication.terminate()` returned false: the quit request
    /// could not be sent. Its own case rather than `.failed(errno: 0)`, since
    /// there is no errno and `0` would be an invented one.
    case quitRequestNotSent
    case failed(errno: Int32)
}

/// Sends Quit / Force Quit to one process, identified by pid AND start time.
///
/// Main-actor because `NSRunningApplication` is AppKit, and every caller is
/// a view acting on a user's click.
@MainActor
public enum ProcessControl {

    /// Re-checks `identity` against the kernel, then acts.
    ///
    /// The identity passed in may be minutes old — it is captured at
    /// right-click and held while a confirmation alert is open. In that time
    /// the process can exit and its pid be reused, so it is read afresh here,
    /// immediately before signalling. A missing process and a pid with a
    /// different start time both throw `.exited`: in the second case the pid
    /// belongs to someone else now, and signalling it would be an action aimed
    /// at the wrong process.
    ///
    /// A window of microseconds remains between the re-check and the signal.
    /// macOS gives an unprivileged, unentitled app no stable handle on
    /// another process, so it cannot be closed; the re-check shrinks it from
    /// "however long the alert was open" to that.
    public static func perform(
        _ action: ProcessAction,
        on identity: ProcessIdentity
    ) throws(ProcessControlError) {
        // See ProcessControlError.notSignallable: kill(2) treats pid 0 as
        // "this process's own group", not kernel_task.
        guard identity.pid > 0 else { throw .notSignallable }

        guard ProcessSampler.identity(of: identity.pid) == identity else {
            throw .exited
        }

        switch action {
        case .quit:
            // A GUI app gets the same request ⌘Q sends, so it can stop to ask
            // about unsaved work. Background-only apps (`.prohibited`) and
            // plain processes have no such handler; they get SIGTERM.
            if let app = NSRunningApplication(processIdentifier: identity.pid),
               app.activationPolicy != .prohibited {
                guard app.terminate() else { throw .quitRequestNotSent }
            } else {
                try send(SIGTERM, to: identity.pid)
            }
        case .forceQuit:
            try send(SIGKILL, to: identity.pid)
        }
    }

    private static func send(_ signal: Int32, to pid: pid_t) throws(ProcessControlError) {
        guard kill(pid, signal) != 0 else { return }
        switch errno {
        case ESRCH: throw .exited
        case EPERM: throw .notPermitted
        case let code: throw .failed(errno: code)
        }
    }
}
