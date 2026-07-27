import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Hardware page")
struct HardwarePageTests {

    private func page(primaryValue: String?, stats: [HardwareStat]) -> some View {
        HardwarePage(
            title: "Memory",
            vendorName: "16 GB LPDDR5",
            showsAppleMark: true,
            primaryValue: primaryValue,
            series: [
                // Wired + App sums to 0.9 at every tick, not just the last —
                // high enough, and flat enough across the whole history,
                // that the stacked total's curve sits within the top ~10%
                // of the chart's canvas across its full width, which is what
                // `rendersFullPage`'s `chartCanvasProbeRegion` probe (a
                // fixed-position rectangle spanning most of the canvas'
                // width) needs to land on real chart content. See
                // `chartCanvasProbeRegion`'s doc comment and
                // `CPUPageTests.rendersFullPageFromStore`'s for the same
                // reasoning applied to a live-store render.
                ChartSeries(name: "Wired", values: [0.45, 0.45, 0.45]),
                ChartSeries(name: "App", values: [0.45, 0.45, 0.45]),
            ],
            accent: Vitals.Palette.memory,
            stats: stats,
            disclosureKey: "test.memory"
        ) {
            Text("secondary")
        } specifications: {
            StatRow(label: "Type", value: "LPDDR5")
        }
    }

    @Test("renders a full page with a value, chart, stats and disclosure")
    func rendersFullPage() throws {
        let view = page(
            primaryValue: "13.9 GB",
            stats: [
                HardwareStat(label: "Installed", value: "16 GB"),
                HardwareStat(label: "Swap", value: "2.1 GB"),
            ]
        )
        let rendered = try renderPNG(view, size: CGSize(width: 800, height: 600), named: "hardware-page")
        // `fileExists` alone is vacuous — `renderPNG` already wrote the file
        // and would have thrown otherwise, so this proved nothing about
        // whether the container actually painted its chart. This is the
        // shared container's only render test, so it gets the same real
        // probe every concrete page's own render test does: see
        // `regionHasSaturatedColor(in:region:matchingHueOf:)`'s doc comment
        // for why matching the non-lead band hue (here, "App", since this
        // page's own two series are `Wired`/`App`) is what actually proves
        // `MetricChart` painted, rather than merely something in the panel.
        let nonLeadHues = Array(Vitals.seriesColors(startingAt: Vitals.Palette.memory, count: 2).dropFirst().map(hue(of:)))
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion, matchingHueOf: nonLeadHues))
    }

    @Test("an absent primary value renders an em dash, never a zero")
    func absentPrimaryValueIsEmDash() {
        #expect(HardwarePage<EmptyView, EmptyView>.displayPrimary(nil) == "—")
        #expect(HardwarePage<EmptyView, EmptyView>.displayPrimary("42%") == "42%")
    }

    @Test("a stat with no reading renders Unavailable, matching StatRow's house rule")
    func absentStatIsUnavailable() {
        // The container must not invent its own wording for absence.
        #expect(StatRow.displayValue(HardwareStat(label: "Speed", value: nil).value) == "Unavailable")
    }

    @Test("stats are identified by label so SwiftUI can diff them")
    func statsAreIdentifiable() {
        let stat = HardwareStat(label: "Installed", value: "16 GB")
        #expect(stat.id == "Installed")
    }

    @Test("a page with no series still renders")
    func emptySeriesRenders() throws {
        let view = HardwarePage(
            title: "GPU",
            vendorName: nil,
            showsAppleMark: false,
            primaryValue: nil,
            series: [],
            accent: Vitals.Palette.gpu,
            stats: [],
            disclosureKey: "test.empty"
        ) {
            EmptyView()
        } specifications: {
            EmptyView()
        }
        let rendered = try renderPNG(view, size: CGSize(width: 600, height: 400), named: "hardware-page-empty")
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
