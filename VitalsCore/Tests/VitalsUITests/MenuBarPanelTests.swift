import AppKit
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

    /// Every row the dropdown shows must actually be one of the series
    /// `MetricsStore.keepWarmSeries` samples for the app's whole lifetime —
    /// otherwise the row would sit empty until something else happened to
    /// subscribe to it. The map from a row's tile id to its `SeriesKey` lives
    /// here, in the test, rather than in production code that has no other
    /// use for it.
    @Test("every row is one of the series kept warm for the app's whole lifetime")
    func everyRowIsKeptWarm() {
        let seriesKey: [String: SeriesKey] = [
            "cpu": .cpu,
            "memory": .memory,
            "gpu": .gpu,
            "storage": .diskIO,
            "network": .network,
        ]
        for id in MenuBarPanel.rowIDs {
            let key = seriesKey[id]
            #expect(key != nil, "no SeriesKey mapping for row \"\(id)\"")
            if let key {
                #expect(
                    MetricsStore.keepWarmSeries.contains(key),
                    "row \"\(id)\" maps to \(key), which MetricsStore.keepWarmSeries does not keep warm"
                )
            }
        }
    }

    /// Each row's sparkline paints in its own subsystem's accent — probed in
    /// its *own* row's band only. A whole-panel probe can't tell two rows with
    /// swapped accents apart, since every hue is still present somewhere in
    /// the panel either way; reversing the rows' rendering order fails this.
    ///
    /// The GPU and Network accents are ~0.04 apart in hue, so the tolerance
    /// stays tight — the default 0.05 would let one pass for the other.
    ///
    /// `rowBand(index:)` below gives each row's own y-range, *derived* from
    /// `MenuBarPanel`'s own named layout constants (`padding`,
    /// `rowInnerSpacing`, `rowSpacing`, `sparklineHeight`) plus one quantity
    /// this codebase does not declare anywhere as a constant — the actual
    /// rendered height of one line of `Vitals.Typography.label` (system
    /// font, size 11, weight medium) — measured once, directly, with the
    /// same `NSHostingView` machinery `renderPNG` uses (see
    /// `measuredLabelLineHeight`), not guessed. `body`'s panel is naturally
    /// shorter than `panelSize.height` (420pt) and SwiftUI centres it, so
    /// getting the first row's absolute top right also means knowing the
    /// footer's natural height — the `Divider()` and the button row are
    /// system chrome with no Vitals-declared size either, so those are
    /// measured the same way rather than guessed. See
    /// `measuredDividerHeight`/`measuredFooterHeight`.
    @Test("with live data, every row's sparkline paints its own accent, in its own row")
    func everyRowPaintsItsAccent() async throws {
        let store = try await liveStore()
        let rendered = try renderPNG(panel(store), size: Self.panelSize, named: "menubar-panel-live")
        let rows: [(accent: Color, band: CGRect)] = [
            (Vitals.Palette.cpu, Self.rowBand(index: 0)),
            (Vitals.Palette.memory, Self.rowBand(index: 1)),
            (Vitals.Palette.gpu, Self.rowBand(index: 2)),
            (Vitals.Palette.storage, Self.rowBand(index: 3)),
            (Vitals.Palette.network, Self.rowBand(index: 4)),
        ]
        for (accent, band) in rows {
            #expect(
                try regionHasSaturatedColor(in: rendered, region: band, matchingHueOf: [hue(of: accent)], tolerance: 0.015),
                "no pixel in hue \(hue(of: accent)) within its own row band \(band)"
            )
        }
    }

    /// One line of `Vitals.Typography.label`'s actual rendered height.
    /// Measured, not guessed: this codebase declares no line-height token
    /// for it, and a system font's line height is resolved by AppKit at
    /// render time, not something Vitals states anywhere as a number.
    private static let measuredLabelLineHeight: CGFloat = {
        let hosting = NSHostingView(rootView: Text("Ag").font(Vitals.Typography.label))
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 200, height: 100))
        return hosting.fittingSize.height
    }()

    /// `Divider()`'s actual rendered thickness — system chrome with no
    /// Vitals-declared size, needed (with `measuredFooterHeight`) to derive
    /// the panel's total natural height, and so where SwiftUI centres it
    /// within `panelSize`.
    private static let measuredDividerHeight: CGFloat = {
        let hosting = NSHostingView(rootView: Divider())
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 200, height: 100))
        return hosting.fittingSize.height
    }()

    /// The footer `HStack { Button; Spacer; Button }`'s actual rendered
    /// height — dominated by the default button style's own chrome, again
    /// not a Vitals-declared size.
    private static let measuredFooterHeight: CGFloat = {
        let footer = HStack {
            Button("Open Vitals") {}
            Spacer()
            Button("Quit Vitals") {}
        }
        let hosting = NSHostingView(rootView: footer)
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 200, height: 100))
        return hosting.fittingSize.height
    }()

    /// One row's own content height: its label line, `rowInnerSpacing`, and
    /// its chart — the same stack `row(_:)` builds.
    private static var rowContentHeight: CGFloat {
        measuredLabelLineHeight + MenuBarPanel.rowInnerSpacing + MenuBarPanel.sparklineHeight
    }

    /// The vertical distance from one row's chart top to the next.
    private static var rowStep: CGFloat { rowContentHeight + MenuBarPanel.rowSpacing }

    /// The panel's own natural (unconstrained) height: `body`'s outer
    /// `VStack` — every row, the divider, the footer, all `MenuBarPanel.rowSpacing`
    /// gaps between them — plus `body`'s own `.padding(MenuBarPanel.padding)`.
    private static var naturalPanelHeight: CGFloat {
        let rowCount = MenuBarPanel.rowIDs.count
        let childCount = rowCount + 2 // + Divider + footer HStack
        let content = CGFloat(rowCount) * rowContentHeight
            + measuredDividerHeight + measuredFooterHeight
            + CGFloat(childCount - 1) * MenuBarPanel.rowSpacing
        return content + 2 * MenuBarPanel.padding
    }

    /// `body`'s content is naturally shorter than `panelSize.height`, and a
    /// `.frame(width:)` with no matching height constraint centres its child
    /// by default — this is that offset.
    private static var contentCenteringOffset: CGFloat {
        (panelSize.height - naturalPanelHeight) / 2
    }

    /// The first row's chart's own top: past the centring offset, the
    /// panel's padding, and the first row's own label line and inner
    /// spacing.
    private static var firstRowChartTop: CGFloat {
        contentCenteringOffset + MenuBarPanel.padding + measuredLabelLineHeight + MenuBarPanel.rowInnerSpacing
    }

    /// A full-width probe band around row `index`'s chart: 6pt of margin
    /// above and below its own `sparklineHeight`, comfortably inside the
    /// ~16pt gap `rowStep - (sparklineHeight + 12)` leaves to its neighbours
    /// on both sides without reaching into them.
    private static func rowBand(index: Int) -> CGRect {
        let top = firstRowChartTop + CGFloat(index) * rowStep - 6
        return CGRect(x: 0, y: top, width: MenuBarPanel.width, height: MenuBarPanel.sparklineHeight + 12)
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


    /// `MetricChart` floors its own height at `Vitals.Metrics.chartHeight`
    /// (132pt) so a full hardware-page chart never collapses. A compact
    /// embedder like this dropdown asks for only 28pt — without a way to
    /// override that floor, the chart still renders at 132pt and, with no
    /// `.clipped()` anywhere in the stack, bleeds straight through whatever
    /// the caller placed below it. This regression test pins the sparkline to
    /// its own 28pt frame directly, independent of the rest of the panel's
    /// layout.
    ///
    /// Probes from y=28 exactly — the frame's own bottom edge, leaving no gap
    /// for a bleed to hide in.
    ///
    /// With `minimumHeight` correctly passed, `MetricChart`'s
    /// `Canvas` already rasterises into a buffer sized to exactly this 28pt
    /// frame, and `Canvas` cannot paint outside its own raster no matter what
    /// an outer view does or doesn't clip — verified directly against this
    /// probe (nothing above alpha 0 past y=27.5pt either way). So
    /// `.clipped()` is inert here now; it is kept only as cheap defense in
    /// depth. What this test actually guards is the real mechanism —
    /// `sparkline` passing `minimumHeight: Self.sparklineHeight`: without it
    /// the chart falls back to `MetricChart`'s 132pt floor and this probe
    /// fails at y=28.
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
