import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Metric tile")
struct MetricTileTests {

    @Test("renders a tile with a value and a sparkline")
    func rendersWithValue() throws {
        let tile = MetricTile(
            label: "CPU",
            value: "18%",
            accent: Vitals.Palette.cpu,
            series: [ChartSeries(name: "CPU", values: [0.1, 0.3, 0.2, 0.5, 0.4])]
        )
        let url = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-cpu")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an unavailable value renders an em dash, never a zero")
    func unavailableRendersEmDash() throws {
        // The never-fabricate rule at the presentation layer: a tile with no
        // reading must not look like a reading of zero.
        let tile = MetricTile(
            label: "Sensors",
            value: nil,
            accent: Vitals.Palette.warning,
            series: []
        )
        let url = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-unavailable")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(MetricTile.displayValue(nil) == "—")
        #expect(MetricTile.displayValue("18%") == "18%")
    }
}
