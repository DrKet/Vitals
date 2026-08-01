import AppKit
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

/// Quits when the window closes — this is a single-window utility, and a
/// lingering invisible process is a real failure mode this project has hit.
///
/// The activation policy that used to live here is now the bundle's job:
/// `Info.plist` makes this a normal windowed app, which is what a SwiftPM
/// executable could not do on its own. `scripts/verify-app.sh` launches the
/// built bundle and asserts a window appears, which is what proves that.
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
