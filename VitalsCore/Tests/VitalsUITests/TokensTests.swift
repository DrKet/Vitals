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
        //
        // `count: 5`, not 6: the base ramp is five hues now that
        // `Palette.warning` is excluded from it (see `seriesRamp`'s doc
        // comment) — this was `6` before that fix, matching the ramp's
        // length at the time. Asking for more than the ramp holds is exactly
        // the wraparound `paletteWrapsRatherThanTruncating` covers, which by
        // construction cannot stay fully distinct, so this test must ask for
        // no more than the ramp's actual length to test what it says it
        // tests.
        let colors = Vitals.seriesColors(startingAt: Vitals.Palette.storage, count: 5)
        #expect(Set(colors.map(String.init(describing:))).count == 5)
    }

    @Test("warning is reserved: it never appears in a chart's colour ramp")
    func warningIsExcludedFromEveryRamp() {
        // `Palette.warning` has no live semantic use today, but reserving it
        // means it stays available for an actual warning later rather than
        // already being spent on whichever data band happened to land on it
        // by rotation (Memory's Cached band, Network's Up band, before this
        // fix). Checked across every page's own accent, plus the default
        // ramp, so no rotation can reintroduce it.
        let leads = [
            Vitals.Palette.cpu, Vitals.Palette.memory, Vitals.Palette.gpu,
            Vitals.Palette.storage, Vitals.Palette.network,
        ]
        for accent in leads {
            let colors = Vitals.seriesColors(startingAt: accent, count: 5)
            #expect(!colors.contains(Vitals.Palette.warning))
        }
        #expect(!Vitals.seriesColors(count: 5).contains(Vitals.Palette.warning))
    }

    /// `Set(colors...).count == 4` (the assertion this replaces) passes for
    /// any four non-identical colours, no matter how close together they
    /// sit — it never actually tested the "distinguishable" its old name
    /// claimed. A senior review found it stays green even though Memory's
    /// own bands 2 and 3 (App, hue ~24.7°, and Compressed, hue ~39.6°) sit
    /// only ~15° apart on the hue wheel with matching saturation and
    /// brightness, adjacent in the stack — close enough that they read as
    /// the same colour at a glance, which is exactly what "distinguishable"
    /// is supposed to rule out.
    ///
    /// This is the honest replacement: a minimum angular gap between every
    /// *adjacent* pair in the stack (adjacent bands are the ones that share
    /// a boundary in a stacked chart, so their hues are what a viewer
    /// actually needs to tell apart — non-adjacent bands never touch, so a
    /// close hue between them would not be a real legibility problem).
    /// 0.1 (36°) is the same threshold and the same hue-in-`0...1`-space
    /// convention `PageRenderRegressionTests.differentPagesPaintDifferentChartColours`
    /// already uses to judge two hues as actually distinguishable.
    ///
    /// This is pre-existing, not a regression, and the palette is out of
    /// scope for this fix — so this test is *expected to fail* on the
    /// current ramp. Left failing deliberately and reported to the palette's
    /// owner rather than loosened to pass: weakening the threshold back down
    /// to let 15° through would recreate exactly the vacuous check this
    /// replaces.
    @Test("Memory's four stacked bands are far enough apart in hue to read as distinct, adjacent pairs included")
    @MainActor
    func memoryFourBandsStayDistinctWithoutWarning() {
        let colors = Vitals.seriesColors(startingAt: Vitals.Palette.memory, count: 4)
        let hues = colors.map(hue(of:))
        for index in 0..<(hues.count - 1) {
            let raw = abs(hues[index] - hues[index + 1])
            let gap = min(raw, 1 - raw)
            #expect(
                gap > 0.1,
                "adjacent bands \(index) and \(index + 1) sit only \(Int((gap * 360).rounded()))° apart in hue"
            )
        }
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
