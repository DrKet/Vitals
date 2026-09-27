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

    /// Each row's sparkline paints in its own subsystem's accent — probed in
    /// its *own* row's band only. Probing the whole panel (as this test
    /// originally did) can't tell two rows with swapped accents apart, since
    /// every hue is still present somewhere in the panel either way; proved
    /// red below by reversing `MenuBarPanel.rowIDs`' rendering order, then
    /// restored.
    ///
    /// The GPU and Network accents are ~0.04 apart in hue, so the tolerance
    /// stays tight — the default 0.05 would let one pass for the other.
    ///
    /// `rowBand(_:)` below gives each row's own y-range. These are pinned,
    /// not computed live, but they were not guessed: derived by rendering
    /// `menubar-panel-live.png` and scanning it (a one-off, throwaway
    /// script, not part of this suite) for each accent's clearly-visible
    /// extent — alpha > 30, saturation spread > 16/255, hue within 0.015 of
    /// the target, at columns spread across the row's width but short of the
    /// live dot's halo near the trailing edge, which is a different colour
    /// story (opacity 0.18, blended with white) and not representative of
    /// the row's own band. That scan found five clean, non-overlapping
    /// bands roughly 54pt apart (consistent with the row layout: 12pt
    /// padding, then repeating units of a ~13pt label line + 4pt spacing +
    /// 28pt chart + 10pt row spacing): CPU 88–94pt, Memory 140–150pt, GPU
    /// 194–206pt, Storage 248–262pt, Network 304–318pt. Each constant below
    /// is a 40pt window centred on one of those, which comfortably contains
    /// its own measured band with margin to spare and leaves a 14pt gap to
    /// its neighbours on both sides — safe even if a row's exact position
    /// drifts a few points with a future layout tweak.
    @Test("with live data, every row's sparkline paints its own accent, in its own row")
    func everyRowPaintsItsAccent() async throws {
        let store = try await liveStore()
        let rendered = try renderPNG(panel(store), size: Self.panelSize, named: "menubar-panel-live")
        let rows: [(accent: Color, band: CGRect)] = [
            (Vitals.Palette.cpu, Self.rowBand(top: 70)),
            (Vitals.Palette.memory, Self.rowBand(top: 124)),
            (Vitals.Palette.gpu, Self.rowBand(top: 178)),
            (Vitals.Palette.storage, Self.rowBand(top: 232)),
            (Vitals.Palette.network, Self.rowBand(top: 286)),
        ]
        for (accent, band) in rows {
            #expect(
                try regionHasSaturatedColor(in: rendered, region: band, matchingHueOf: [hue(of: accent)], tolerance: 0.015),
                "no pixel in hue \(hue(of: accent)) within its own row band \(band)"
            )
        }
    }

    /// A 40pt-tall, full-width probe band starting at `top`. See
    /// `everyRowPaintsItsAccent`'s doc comment for where the five `top`
    /// values (70, 124, 178, 232, 286) come from.
    private static func rowBand(top: CGFloat) -> CGRect {
        CGRect(x: 0, y: top, width: MenuBarPanel.width, height: 40)
    }

    /// Nothing measured must paint nothing: no zero-height bars or flat
    /// sparklines in an accent, which would read as a measured zero.
    @Test("with an empty store, the dropdown paints no accent colour anywhere")
    func emptyStorePaintsNoAccent() throws {
        let empty = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(panel(empty), size: Self.panelSize, named: "menubar-panel-empty")
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(origin: .zero, size: Self.panelSize)))
    }

    /// Unlike the panel's rows, the label isn't inside a `GlassPanel`, so
    /// `regionHasContent` (not `regionHasSaturatedColor`) is the right probe
    /// here — see its own doc comment on why a saturation probe is needed
    /// only once a `GlassPanel` material sits behind the content. A prior
    /// version of this test only checked that rendering didn't throw, which
    /// would still pass for a label whose body drew nothing at all.
    @Test("the menu-bar label renders with and without a store")
    func labelRenders() async throws {
        let labelRect = CGRect(x: 0, y: 0, width: 160, height: 22)
        let empty = try renderPNG(MenuBarLabel(store: nil), size: labelRect.size, named: "menubar-label-empty")
        #expect(try regionHasContent(in: empty, region: labelRect))
        let store = try await liveStore()
        let live = try renderPNG(MenuBarLabel(store: store), size: labelRect.size, named: "menubar-label-live")
        #expect(try regionHasContent(in: live, region: labelRect))
    }

    /// `row(_:)` must reserve a chart band only when there is real chart
    /// data — the same rule `MetricTile` uses (`series.contains(where: {
    /// !$0.values.isEmpty })`, `MetricTile.swift` ~line 50), not the looser
    /// `!series.isEmpty`. The CPU tile's series is always exactly one
    /// `ChartSeries`, so on a freshly empty store it is present but carries
    /// no values — `!series.isEmpty` would still be true and the CPU row
    /// would reserve a chart (drawing faint gridlines) for a reading that
    /// was never taken.
    @Test("hasChartData mirrors MetricTile's emptiness rule: no series, or series with no values, is not chart data")
    func hasChartDataMatchesMetricTileRule() {
        #expect(MenuBarPanel.hasChartData([]) == false)
        #expect(MenuBarPanel.hasChartData([ChartSeries(name: "CPU", values: [], timestamps: [])]) == false)
        #expect(MenuBarPanel.hasChartData([ChartSeries(name: "CPU", values: [0.4], timestamps: [1000])]) == true)
    }

    /// `MetricChart` floors its own height at `Vitals.Metrics.chartHeight`
    /// (132pt) so a full hardware-page chart never collapses. A compact
    /// embedder like this dropdown asks for only 28pt — without a way to
    /// override that floor, the chart still renders at 132pt and, with no
    /// `.clipped()` anywhere in the stack, bleeds straight through whatever
    /// the caller placed below it. This regression test pins the sparkline to
    /// its own 28pt frame directly, independent of the rest of the panel's
    /// layout.
    ///
    /// Probes from y=28 exactly — the frame's own bottom edge, not y=32 as
    /// this test originally did; that 4pt gap meant removing `.clipped()`
    /// alone could still pass.
    ///
    /// It still does: with `minimumHeight` correctly passed, `MetricChart`'s
    /// `Canvas` already rasterises into a buffer sized to exactly this 28pt
    /// frame, and `Canvas` cannot paint outside its own raster no matter what
    /// an outer view does or doesn't clip — verified directly against this
    /// probe (nothing above alpha 0 past y=27.5pt either way). So
    /// `.clipped()` is inert here now; it is kept only as cheap defense in
    /// depth. What this test actually guards is the real mechanism —
    /// `sparkline` passing `minimumHeight: Self.sparklineHeight` — proved red
    /// by temporarily omitting that argument (reverting to `MetricChart`'s
    /// 132pt default): this probe then failed at y=28 exactly as it should.
    /// Restored; green again.
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
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(x: 0, y: 28, width: 300, height: 60)))
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
