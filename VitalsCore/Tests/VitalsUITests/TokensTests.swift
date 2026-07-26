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

    @Test("the default ramp already starts at the CPU hue")
    func defaultRampStartsAtCPU() {
        // `seriesColors(count:)` is a thin wrapper over
        // `seriesColors(startingAt:count:)` — this pins that the wrapper
        // still starts at `Palette.cpu`, so existing charts (and the other
        // assertions in this suite) do not shift under the refactor.
        #expect(Vitals.seriesColors(count: 3) == Vitals.seriesColors(startingAt: Vitals.Palette.cpu, count: 3))
    }

    @Test("a page's accent leads its own chart's colour ramp")
    func accentLeadsItsOwnRamp() {
        // This is the fix: every hardware page used to render in CPU blue
        // regardless of its own hue, because the container always called
        // `seriesColors(count:)`. Each page's accent must now come first.
        #expect(Vitals.seriesColors(startingAt: Vitals.Palette.memory, count: 4).first == Vitals.Palette.memory)
        #expect(Vitals.seriesColors(startingAt: Vitals.Palette.gpu, count: 2).first == Vitals.Palette.gpu)
        #expect(Vitals.seriesColors(startingAt: Vitals.Palette.storage, count: 2).first == Vitals.Palette.storage)
        #expect(Vitals.seriesColors(startingAt: Vitals.Palette.network, count: 2).first == Vitals.Palette.network)
    }

    @Test("rotating the ramp still never repeats a colour before wrapping")
    func rotatedRampStaysDistinct() {
        // Storage's own hue already sits in the base ramp, so naively
        // prepending it (rather than rotating) would duplicate it at
        // position 0 and its original position — indistinguishable Read/Write
        // bands on the Storage page. Rotation avoids that: every hue from the
        // base ramp appears exactly once, just reordered.
        let colors = Vitals.seriesColors(startingAt: Vitals.Palette.storage, count: 6)
        #expect(Set(colors.map(String.init(describing:))).count == 6)
    }

    @Test("an accent absent from the base ramp still leads, falling back to the unrotated ramp for the rest")
    func unknownAccentStillLeads() {
        let mystery = Color(red: 0.1, green: 0.2, blue: 0.3)
        let colors = Vitals.seriesColors(startingAt: mystery, count: 2)
        #expect(colors.first == mystery)
    }

    @Test("layout metrics are positive and ordered sensibly")
    func layoutMetricsAreSane() {
        #expect(Vitals.Metrics.cornerRadius > 0)
        #expect(Vitals.Metrics.tileSpacing > 0)
        #expect(Vitals.Metrics.contentPadding >= Vitals.Metrics.tileSpacing)
        #expect(Vitals.Metrics.chartHeight > Vitals.Metrics.contentPadding)
    }

    @Test("an absent byte count formats as nil, never as a baked-in placeholder")
    func formatByteCountIsNilForAbsentReading() {
        #expect(Vitals.formatByteCount(Int?.none) == nil)
        #expect(Vitals.formatByteCount(UInt64?.none) == nil)
    }

    @Test("a present byte count formats as non-empty text, for any integer width")
    func formatByteCountFormatsAnyIntegerWidth() {
        #expect(Vitals.formatByteCount(4_194_304)?.contains("4") == true)
        #expect(Vitals.formatByteCount(UInt64(1_073_741_824))?.isEmpty == false)
    }

    @Test("a byte count that cannot be absent formats without an absence branch")
    func formatKnownByteCountNeedsNoFallback() {
        // The force-unwrap inside `formatKnownByteCount` is what lets callers
        // with plain, non-optional byte counts — a volume's used/total bytes, a
        // GPU memory topology's size — skip writing an `?? "…"` fallback that
        // could never actually render. These assertions pin that it holds for
        // both integer widths in use, including the zero edge.
        #expect(Vitals.formatKnownByteCount(UInt64(1_073_741_824)).isEmpty == false)
        #expect(Vitals.formatKnownByteCount(4_194_304).contains("4"))
        #expect(Vitals.formatKnownByteCount(UInt64(0)).isEmpty == false)
    }
}
