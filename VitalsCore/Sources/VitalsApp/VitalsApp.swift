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

    /// Starts the engine exactly once, however many times this is called.
    /// `VitalsApp.init` is the primary trigger — SwiftUI calls it exactly
    /// once per process, so it can't fail to run the way a view's `.task`
    /// might: it's undocumented whether SwiftUI runs lifecycle modifiers on
    /// a status-item label at all, or whether it runs if the item is
    /// disallowed or hidden. The menu-bar label's and the main window's own
    /// `.task { await model.startIfNeeded() }` are idempotent backups, not
    /// the trigger this depends on — `didStart` below is what makes any
    /// number of callers, in any order, safe.
    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        do {
            // `HardwareProfile.detect()` is synchronous and shells out to
            // `system_profiler` (`waitUntilExit`); running that on the main
            // actor would block the app's very first frame. Detached keeps
            // launch responsive; the result is only ever touched back on
            // the main actor below. `.userInitiated`: a detached task does
            // not inherit the caller's priority, and this holds one pool
            // thread for `system_profiler`'s whole run — acceptable once,
            // at launch, but not worth risking at a background priority
            // that could get starved behind other work.
            let profile = try await Task.detached(priority: .userInitiated) {
                try HardwareProfile.detect()
            }.value
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
    @State private var model: AppModel

    /// SwiftUI calls an `App`'s `init` exactly once per process — the one
    /// truly guaranteed-once entry point, unlike any view's `.task` (see
    /// `AppModel.startIfNeeded()`). `AppModel.init` itself stays
    /// side-effect free; starting the engine is this call, explicitly.
    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        Task { await model.startIfNeeded() }
    }

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
                // Backup trigger, not the primary one — `VitalsApp.init`
                // already started this. See `AppModel.startIfNeeded()`.
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
        // Backup trigger, not the primary one — `VitalsApp.init` already
        // started this. See `AppModel.startIfNeeded()`.
        .task { await model.startIfNeeded() }
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
