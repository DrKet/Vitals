import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Menu-bar panel")
struct MenuBarPanelTests {

    private static let panelSize = CGSize(width: MenuBarPanel.width, height: 420)

    /// A store holding a few ticks of every kept-warm series, so each row has
    /// a value and a sparkline. The real hardware profile, so memory has a
    /// total and the GPU attribution gate sees this machine's GPU count.
    private func liveStore() async throws -> MetricsStore {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let busyBox = BusyBox()
        await engine.register(AnySampler {
            let busy = busyBox.next()
            return CPULoadSample(cores: [CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0)])
        }, for: .cpu, cadence: .fast)
        let profile = try HardwareProfile.detect()
        let total = profile.memory.totalBytes
        await engine.register(AnySampler {
            MemorySample(app: total * 4 / 10, wired: total * 3 / 10, compressed: 0, cached: 0,
                         free: total * 3 / 10, swapUsed: nil, swapTotal: nil, pressure: nil)
        }, for: .memory, cadence: .fast)
        let gpuCount = profile.gpus.count
        await engine.register(AnySampler {
            Array(repeating: GPUSample(deviceUtilisation: 0.8, rendererUtilisation: 0.6, tilerUtilisation: 0.2,
                                       inUseMemoryBytes: 1_000, allocatedMemoryBytes: 2_000), count: gpuCount)
        }, for: .gpu, cadence: .fast)
        await engine.register(AnySampler {
            ["disk0": DiskThroughput(bytesReadPerSecond: 4_194_304, bytesWrittenPerSecond: 524_288)]
        }, for: .diskIO, cadence: .fast)
        await engine.register(AnySampler {
            ["en0": NetworkThroughput(bytesInPerSecond: 4_194_304, bytesOutPerSecond: 524_288)]
        }, for: .network, cadence: .fast)

        let store = MetricsStore(engine: engine, profile: profile)
        let tasks = [SeriesKey.cpu, .memory, .gpu, .diskIO, .network].map { key in
            Task { await store.stream(key) }
        }
        try await waitUntil {
            store.cpuHistory.count >= 3 && store.memoryHistory.count >= 3 && store.gpuHistory.count >= 3
                && store.diskIOHistory.count >= 3 && store.networkHistory.count >= 3
        }
        tasks.forEach { $0.cancel() }
        return store
    }

    private func panel(_ store: MetricsStore) -> MenuBarPanel {
        MenuBarPanel(store: store, onOpenPage: { _ in }, onOpenVitals: {}, onQuit: {})
    }

    @Test("the dropdown shows the five kept-warm subsystems, in Overview order, each opening its own page")
    func rowsAreTheKeptWarmTilesInOrder() {
        #expect(MenuBarPanel.rowIDs == ["cpu", "memory", "gpu", "storage", "network"])
        for id in MenuBarPanel.rowIDs {
            #expect(SidebarSection(rawValue: id) != nil)
        }
    }

    /// Each row's sparkline paints in its own subsystem's accent. The GPU and
    /// Network accents are ~0.04 apart in hue, so the tolerance is tight —
    /// the default 0.05 would let one pass for the other.
    @Test("with live data, every row's sparkline paints its own accent")
    func everyRowPaintsItsAccent() async throws {
        let store = try await liveStore()
        let rendered = try renderPNG(panel(store), size: Self.panelSize, named: "menubar-panel-live")
        let whole = CGRect(origin: .zero, size: Self.panelSize)
        for accent in [Vitals.Palette.cpu, Vitals.Palette.memory, Vitals.Palette.gpu,
                       Vitals.Palette.storage, Vitals.Palette.network] {
            #expect(
                try regionHasSaturatedColor(in: rendered, region: whole, matchingHueOf: [hue(of: accent)], tolerance: 0.015),
                "no pixel in hue \(hue(of: accent))"
            )
        }
    }

    /// Nothing measured must paint nothing: no zero-height bars or flat
    /// sparklines in an accent, which would read as a measured zero.
    @Test("with an empty store, the dropdown paints no accent colour anywhere")
    func emptyStorePaintsNoAccent() throws {
        let empty = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(panel(empty), size: Self.panelSize, named: "menubar-panel-empty")
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(origin: .zero, size: Self.panelSize)))
    }

    @Test("the menu-bar label renders with and without a store")
    func labelRenders() async throws {
        _ = try renderPNG(MenuBarLabel(store: nil), size: CGSize(width: 160, height: 22), named: "menubar-label-empty")
        let store = try await liveStore()
        _ = try renderPNG(MenuBarLabel(store: store), size: CGSize(width: 160, height: 22), named: "menubar-label-live")
    }

    /// `MetricChart` floors its own height at `Vitals.Metrics.chartHeight`
    /// (132pt) so a full hardware-page chart never collapses. A compact
    /// embedder like this dropdown asks for only 28pt — without a way to
    /// override that floor, the chart still renders at 132pt and, with no
    /// `.clipped()` anywhere in the stack, bleeds straight through whatever
    /// the caller placed below it. This regression test pins the sparkline to
    /// its own 28pt frame directly, independent of the rest of the panel's
    /// layout.
    @Test("a compact sparkline paints nothing outside its own frame")
    func compactChartStaysInItsFrame() throws {
        let series = [ChartSeries(name: "CPU", values: [0.2, 0.9, 0.4, 0.8],
                                  timestamps: [1000, 1001, 1002, 1003])]
        let row = VStack(spacing: 0) {
            MenuBarPanel.sparkline(series: series, accent: Vitals.Palette.cpu)
            Color.clear.frame(height: 60)
        }
        let rendered = try renderPNG(row, size: CGSize(width: 300, height: 88), named: "menubar-sparkline-bounds")
        // The chart has the top 28pt; nothing it draws may reach the 60pt below.
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(x: 0, y: 32, width: 300, height: 56)))
        // Non-vacuous: it did paint inside its own frame.
        #expect(try regionHasSaturatedColor(in: rendered, region: CGRect(x: 0, y: 0, width: 300, height: 28)))
    }
}

/// A cycling CPU-busy value shared with a `@Sendable` sampler closure. Swift 6
/// strict concurrency forbids capturing a local `var` in a `@Sendable`
/// closure directly (`reference to captured var 'busy' in
/// concurrently-executing code`), so the mutable state lives behind a lock
/// instead — the same pattern `MetricsStoreTests.ValueBox` already uses for a
/// sampler fixture with state.
private final class BusyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = 0.2

    func next() -> Double {
        lock.withLock {
            busy = busy >= 0.9 ? 0.2 : busy + 0.1
            return busy
        }
    }
}
