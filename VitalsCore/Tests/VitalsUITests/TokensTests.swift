import SwiftUI
import Testing
@testable import VitalsUI

@Suite("Design tokens")
struct TokensTests {

    @Test("series colours are stable for a given index")
    func seriesColoursAreStable() {
        #expect(Vitals.seriesColors(count: 4) == Vitals.seriesColors(count: 4))
    }

    @Test("series colours never repeat within one chart")
    func seriesColoursAreDistinct() {
        // Four is the widest decomposition the spec calls for — the Memory page's
        // wired / active / compressed / cached breakdown.
        let colors = Vitals.seriesColors(count: 4)
        #expect(colors.count == 4)
        #expect(Set(colors.map(String.init(describing:))).count == 4)
    }

    @Test("asking for more series than the palette holds still returns that many")
    func paletteWrapsRatherThanTruncating() {
        #expect(Vitals.seriesColors(count: 9).count == 9)
    }

    @Test("asking for no series returns nothing")
    func zeroSeriesIsEmpty() {
        #expect(Vitals.seriesColors(count: 0).isEmpty)
    }

    @Test("layout metrics are positive and ordered sensibly")
    func layoutMetricsAreSane() {
        #expect(Vitals.Metrics.cornerRadius > 0)
        #expect(Vitals.Metrics.tileSpacing > 0)
        #expect(Vitals.Metrics.contentPadding >= Vitals.Metrics.tileSpacing)
        #expect(Vitals.Metrics.chartHeight > Vitals.Metrics.contentPadding)
    }
}
