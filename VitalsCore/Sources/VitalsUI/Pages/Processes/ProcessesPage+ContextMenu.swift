import AppKit
import ProcessControl
import SwiftUI
import SystemMetrics

/// The right-click context menu on the Processes table, and the actions it
/// can perform on a row's process.
///
/// Split out of `ProcessesPage.swift` purely for length — this is still the
/// same type, sharing its `@State` (`pendingAction`, `failureMessage`) and
/// its private helpers, not a separate component with its own state.
extension ProcessesPage {

    /// The context menu for one right-clicked pid.
    ///
    /// Resolved through the unfiltered rows to a full row — and so to an
    /// identity — before anything is offered. The executable path is read
    /// here, for this one process when the menu opens, never per tick.
    @ViewBuilder
    func processMenu(for pid: pid_t, in all: [ProcessRow]) -> some View {
        if let row = all.first(where: { $0.pid == pid }) {
            let path = ProcessSampler.executablePath(of: row.pid)
            let state = ProcessMenu.state(
                for: row, currentUserID: getuid(), ownPID: getpid(), executablePath: path
            )

            Button("Copy PID") { copyToPasteboard("\(row.pid)") }
            Button("Copy Name") { copyToPasteboard(row.name) }
            Button("Reveal in Finder") { path.map { reveal(pid: row.pid, executablePath: $0) } }
                .disabled(!state.canReveal)

            Divider()

            Button("Quit…") {
                pendingAction = PendingProcessAction(identity: row.identity, name: row.name, action: .quit)
            }
            .disabled(state.quitUnavailable != nil)
            Button("Force Quit…") {
                pendingAction = PendingProcessAction(identity: row.identity, name: row.name, action: .forceQuit)
            }
            .disabled(state.quitUnavailable != nil)

            if let reason = state.quitUnavailable {
                Divider()
                Text(reason.explanation)
            }
        } else {
            Text("Process has exited")
        }
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Selects the app bundle for a GUI app (`Safari.app`, not the binary
    /// inside it), otherwise the executable. Only reachable when a path is
    /// known — the menu disables the item otherwise.
    func reveal(pid: pid_t, executablePath path: String) {
        let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
            ?? URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func perform(_ action: ProcessAction, on pending: PendingProcessAction) {
        do {
            try ProcessControl.perform(action, on: pending.identity)
        } catch {
            let message = ProcessMenu.failureMessage(error, name: pending.name)
            // Presented a turn later: this runs inside the confirmation
            // alert's button action, and SwiftUI can drop an alert presented
            // while another is still dismissing — which would make the
            // failure silent.
            Task { @MainActor in failureMessage = message }
        }
        // No optimistic removal: the next sample shows the row gone — or
        // still running, if the app stopped to ask about saving.
    }
}
