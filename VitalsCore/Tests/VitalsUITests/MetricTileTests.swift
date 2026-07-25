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
        // No region-specific assertion: the sparkline's shape depends on the
        // chart's own geometry (already covered by `MetricChartTests` and
        // `ChartGeometryTests`), so the harness's whole-image blank check is
        // the right amount of assertion for the tile's own layout.
        _ = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-cpu")
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
        // The label and em dash are the real assertions below; rendering here
        // only proves the nil-value path doesn't crash and isn't a uniformly
        // blank image (renderPNG's own check).
        _ = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-unavailable")
        #expect(MetricTile.displayValue(nil) == "—")
        #expect(MetricTile.displayValue("18%") == "18%")
    }
}
