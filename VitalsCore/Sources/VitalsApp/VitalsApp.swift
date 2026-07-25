import AppKit
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

/// Promotes the process to a normal windowed app.
///
/// A SwiftPM executable has no bundle and no `Info.plist`, so AppKit launches it
/// as a background-only process: `WindowGroup` builds its scene but no window is
/// ever ordered on screen, and the app is invisible while appearing to run
/// perfectly. Setting the policy explicitly is what a bundle's `Info.plist`
/// would otherwise do. Remove this when the app gains a real bundle in M2.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quit when the window closes — this is a single-window utility, and a
    /// lingering invisible process is exactly the failure mode above.
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
