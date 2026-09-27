import AppKit
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

/// Keeps Vitals running when its window closes: the menu-bar item carries it
/// from then on, and the Dock icon goes with the window (`AppLifecycle`).
/// Quit is explicit — the dropdown's Quit Vitals, or ⌘Q.
///
/// A windowless Vitals is intended now, and always visible in the menu bar.
/// The trap to still watch for is different: running the raw executable
/// outside a bundle — `swift run VitalsApp`, or the binary under `.build/`
/// — launches background-only with zero windows *and no menu-bar item*. Use
/// `scripts/build-app.sh && open build/Vitals.app`; `scripts/verify-app.sh`
/// is what proves a window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// State both scenes share, created once for the app's lifetime: the store
/// (and so every series' history), warm sampling, and which page the window
/// shows. Held here rather than in the window so closing and reopening the
/// window never rebuilds it.
@MainActor
@Observable
final class AppModel {
    private(set) var store: MetricsStore?
    private(set) var startupError: String?
    var selection: SidebarSection = .overview
    private var warmSampling: Task<Void, Never>?

    init() {
        Task { await start() }
    }

    private func start() async {
        do {
            let profile = try HardwareProfile.detect()
            let engine = MetricsEngine()
            await StandardSamplers.registerAll(on: engine)
            let store = MetricsStore(engine: engine, profile: profile)
            self.store = store
            // The menu-bar readout and dropdown show exactly the kept-warm
            // series, so they sample for as long as the app runs — with or
            // without a window. See `MetricsStore.keepWarm()`.
            warmSampling = Task { await store.keepWarm() }
        } catch {
            // Surfaced rather than swallowed: if the machine cannot describe its
            // own hardware, saying so beats an empty window.
            startupError = "Could not read this machine's hardware: \(error)"
        }
    }
}

enum MainWindow {
    static let id = "main"
}

@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // `Window`, not `WindowGroup`: one main window. `openWindow(id:)` then
        // brings that window back instead of opening a second one.
        Window("Vitals", id: MainWindow.id) {
            MainWindowContent(model: model)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MainWindowContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let store = model.store {
                AppShell(store: store, selection: $model.selection)
            } else if let startupError = model.startupError {
                Text(startupError)
                    .padding()
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { NSApp.setActivationPolicy(AppLifecycle.activationPolicy(mainWindowOpen: true)) }
        .onDisappear { NSApp.setActivationPolicy(AppLifecycle.activationPolicy(mainWindowOpen: false)) }
    }
}

private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let store = model.store {
            MenuBarPanel(
                store: store,
                onOpenPage: { section in
                    model.selection = section
                    showMainWindow()
                },
                onOpenVitals: showMainWindow,
                onQuit: { NSApp.terminate(nil) }
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.startupError ?? "Starting…")
                Button("Quit Vitals") { NSApp.terminate(nil) }
            }
            .padding(12)
            .frame(width: MenuBarPanel.width)
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(AppLifecycle.activationPolicy(mainWindowOpen: true))
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}
