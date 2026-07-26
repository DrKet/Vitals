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
                ChartSeries(name: "Wired", values: [0.2, 0.3, 0.25]),
                ChartSeries(name: "App", values: [0.3, 0.3, 0.35]),
            ],
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
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
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
