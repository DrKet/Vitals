import AppKit
import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

/// Keeps Vitals running when its window closes: the menu-bar item carries it
/// from then on, and the Dock icon goes with the window (`AppLifecycle`).
/// Quit is explicit — the dropdown's Quit Vitals, or ⌘Q.
///
/// A windowless Vitals is intended now, and present in the menu bar. The
/// trap to still watch for is different: running the raw executable
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
    /// Runs for the app's whole lifetime, with or without a window. The
    /// handle is kept — not just fired and forgotten — for the planned
    /// "throttle sampling while the dropdown is closed" slice, which will
    /// need to cancel and restart it.
    private var warmSampling: Task<Void, Never>?
    /// Set synchronously, before `startIfNeeded()`'s first suspension point,
    /// so a second call — from a second view's `.task`, or a re-run of the
    /// same one — can't start a second engine on top of the first.
    private var didStart = false

    /// Starts the engine exactly once. Called from the menu-bar label's
    /// `.task` rather than from `init`: the label is the one thing on
    /// screen for the app's entire life, with or without the main window,
    /// so it's the one call site guaranteed to run at launch regardless of
    /// window state — unlike a `.task` on the window's own content, which
    /// wouldn't run at all if the window starts closed.
    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        do {
            // `HardwareProfile.detect()` is synchronous and shells out to
            // `system_profiler` (`waitUntilExit`); running that on the main
            // actor would block the app's very first frame. Detached keeps
            // launch responsive; the result is only ever touched back on
            // the main actor below.
            let profile = try await Task.detached { try HardwareProfile.detect() }.value
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
        // Vitals can now quit with its window closed (`AppDelegate` above),
        // so without this, SwiftUI state restoration could relaunch straight
        // into that state: no window, so `.onAppear` never fires, and the
        // bundle's default `.regular` activation policy is left stuck with a
        // Dock icon and nothing to show for it. Pin the window open on every
        // launch instead — `AppLifecycle` still owns the accessory/regular
        // decision from then on, as the window opens and closes.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(store: model.store)
                // The menu-bar label is on screen for the app's whole life,
                // window or not, so it's where the engine starts. See
                // `AppModel.startIfNeeded()`.
                .task { await model.startIfNeeded() }
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
