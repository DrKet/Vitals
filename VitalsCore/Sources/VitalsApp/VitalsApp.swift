import MetricsEngine
import SwiftUI
import SystemMetrics
import VitalsUI

@main
struct VitalsApp: App {
    @State private var store: MetricsStore?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup("Vitals") {
            Group {
                if let store {
                    Text("CPU: \(store.cpu.map { "\(Int($0.total * 100))%" } ?? "—")")
                        .task { await store.stream(.cpu) }
                } else if let startupError {
                    Text(startupError)
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
        guard store == nil, startupError == nil else { return }
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
