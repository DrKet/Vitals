import Darwin
import Foundation
import ProcessControl
import SystemMetrics

/// Why Quit… and Force Quit… are disabled for a row. The menu shows the
/// explanation as a disabled line, so a greyed-out Quit is never unexplained.
public enum QuitUnavailableReason: Equatable, Sendable {
    /// pid 0 or 1. Not quittable by anyone — administrator access would not
    /// help, so the menu must not suggest it would.
    case systemCritical
    /// Vitals' own process. Quitting Vitals belongs in its app menu.
    case isVitals
    /// Root's or another user's process. Goes away when the privileged helper
    /// exists.
    case needsAdministrator

    public var explanation: String {
        switch self {
        case .systemCritical: "System process — can’t be quit"
        case .isVitals: "Quit Vitals from its app menu"
        case .needsAdministrator: "Quitting this process needs administrator access"
        }
    }
}

public struct ProcessMenuState: Equatable, Sendable {
    /// `nil` means Quit… and Force Quit… are enabled.
    public var quitUnavailable: QuitUnavailableReason?
    public var canReveal: Bool
}

/// The action a confirmation alert is waiting on. Holds the identity captured
/// at right-click — `ProcessControl.perform` re-checks it on confirm.
struct PendingProcessAction: Equatable {
    let identity: ProcessIdentity
    let name: String
    let action: ProcessAction
}

/// Pure model behind the Processes context menu: what is enabled, and every
/// word the menu and its alerts say. The view only renders it.
public enum ProcessMenu {

    public static func state(
        for row: ProcessRow,
        currentUserID: uid_t,
        ownPID: pid_t,
        executablePath: String?
    ) -> ProcessMenuState {
        ProcessMenuState(
            quitUnavailable: quitUnavailableReason(for: row, currentUserID: currentUserID, ownPID: ownPID),
            canReveal: executablePath != nil
        )
    }

    /// First match wins. System-critical is checked before ownership because
    /// pids 0 and 1 are root's, and "needs administrator access" would be a
    /// false promise for them.
    private static func quitUnavailableReason(
        for row: ProcessRow, currentUserID: uid_t, ownPID: pid_t
    ) -> QuitUnavailableReason? {
        if row.pid == 0 || row.pid == 1 { return .systemCritical }
        if row.pid == ownPID { return .isVitals }
        if row.userID != currentUserID { return .needsAdministrator }
        return nil
    }

    public static let confirmationTitle = "Are you sure you want to quit this process?"

    public static func confirmationMessage(name: String, pid: pid_t) -> String {
        "“\(name)” (PID \(pid)). Force Quit stops it immediately; unsaved changes may be lost."
    }

    public static let failureTitle = "Couldn’t Quit Process"

    public static func failureMessage(_ error: ProcessControlError, name: String) -> String {
        switch error {
        case .exited:
            "“\(name)” couldn’t be quit because it has already exited."
        case .notPermitted:
            "“\(name)” couldn’t be quit because you don’t have permission."
        case .notSignallable:
            "“\(name)” is a system process and can’t be quit."
        case .quitRequestNotSent:
            "“\(name)” couldn’t be asked to quit. Try Force Quit."
        case .failed(let code):
            "“\(name)” couldn’t be quit: \(String(cString: strerror(code)))."
        }
    }
}
