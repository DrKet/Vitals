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

    @Test("a tile with a fraction draws a proportion bar")
    func fractionDrawsBar() throws {
        // Empty series so the ONLY saturated content the tile can draw is the
        // bar's accent fill — the label and value are neutral/white. That
        // isolates "is there a bar?" to a whole-tile saturation probe, with no
        // pixel-precise coordinates to drift.
        let tile = MetricTile(
            label: "CPU", value: "50%", accent: Vitals.Palette.cpu,
            fraction: 0.5, series: []
        )
        let image = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-bar-present")
        #expect(try regionHasSaturatedColor(in: image, region: CGRect(x: 0, y: 0, width: 260, height: 150)))
    }

    @Test("a tile with no fraction draws no bar")
    func noFractionNoBar() throws {
        // The never-fabricate rule for the bar: no whole, no bar. With an empty
        // series and a nil fraction, nothing saturated is drawn at all.
        let tile = MetricTile(
            label: "Storage", value: "5.28 MB/s", accent: Vitals.Palette.storage,
            fraction: nil, series: []
        )
        let image = try renderPNG(tile, size: CGSize(width: 260, height: 150), named: "tile-bar-absent")
        #expect(try !regionHasSaturatedColor(in: image, region: CGRect(x: 0, y: 0, width: 260, height: 150)))
    }
}
