import AppKit
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

/// Quits when the window closes — this is a single-window utility, and a
/// lingering invisible process is a real failure mode this project has hit.
///
/// The activation policy that used to live here is now automatic: AppKit
/// defaults a bundled `.app`'s activation policy to `.regular` on its own.
/// `Info.plist`'s role is only the *absence* of `LSUIElement` /
/// `LSBackgroundOnly` — either would opt back out of that default.
///
/// That default only applies to a real bundle. Running the raw executable
/// outside one — `swift run VitalsApp`, or the binary under `.build/`
/// directly — still launches background-only with zero windows; this is the
/// trap Task 4 found and the one the next person will hit again if they reach
/// for `swift run` out of habit. Use `scripts/build-app.sh && open
/// build/Vitals.app` instead. `scripts/verify-app.sh` is what actually proves
/// a window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MetricsStore?
    @State private var startupError: String?
    /// Set synchronously before the first suspension point, so a second window
    /// opening mid-launch cannot run startup a second time.
    @State private var didStart = false

    var body: some Scene {
        WindowGroup("Vitals") {
            Group {
                if let store {
                    AppShell(store: store)
                } else if let startupError {
                    Text(startupError)
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .task { await start() }
        }
        .windowStyle(.hiddenTitleBar)
    }

    private func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            let profile = try HardwareProfile.detect()
            let engine = MetricsEngine()
            await StandardSamplers.registerAll(on: engine)
            store = MetricsStore(engine: engine, profile: profile)
        } catch {
            // Surfaced rather than swallowed: if the machine cannot describe its
            // own hardware, saying so beats an empty window.
            startupError = "Could not read this machine's hardware: \(error)"
        }
    }
}
