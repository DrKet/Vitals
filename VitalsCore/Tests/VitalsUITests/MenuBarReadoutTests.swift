import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Menu-bar readout")
struct MenuBarReadoutTests {

    private static func cpu(_ busy: Double) -> CPULoadSample {
        CPULoadSample(cores: [CoreLoad(user: busy, system: 0, idle: 1 - busy, nice: 0)])
    }

    private static func memory(usedGiB: UInt64) -> MemorySample {
        let gib: UInt64 = 1 << 30
        return MemorySample(
            app: usedGiB * gib, wired: 0, compressed: 0, cached: 0,
            free: 0, swapUsed: nil, swapTotal: nil, pressure: nil
        )
    }

    @Test("CPU reads as the Overview tile's whole percentage, padded to three digits")
    func cpuPercentage() {
        #expect(MenuBarReadout.cpu(Self.cpu(0.234)) == "\u{2007}23%")
        #expect(MenuBarReadout.cpu(Self.cpu(1.0)) == "100%")
    }

    @Test("memory reads as used over total, as a whole percentage, padded to three digits")
    func memoryPercentage() {
        let total: UInt64 = 16 << 30
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: total) == "\u{2007}25%")
    }

    /// The spec: digits monospaced so the item's width does not jitter as
    /// values change. `.monospacedDigit()` equalises digit *widths* but not
    /// digit *count* — "9%" -> "10%" -> "100%" still changes width on every
    /// tick. Padding every numeric reading to three digits with leading
    /// FIGURE SPACES (U+2007, exactly one digit wide) keeps every reading at
    /// the same 3-digit-plus-percent width: 4 characters.
    @Test("every numeric reading has the same width in digits")
    func numericReadingsShareAWidth() {
        #expect(MenuBarReadout.cpu(Self.cpu(0.09)) == "\u{2007}\u{2007}9%")
        #expect(MenuBarReadout.cpu(Self.cpu(0.23)) == "\u{2007}23%")
        #expect(MenuBarReadout.cpu(Self.cpu(1.0)) == "100%")
        for reading in [
            MenuBarReadout.cpu(Self.cpu(0.09)),
            MenuBarReadout.cpu(Self.cpu(0.23)),
            MenuBarReadout.cpu(Self.cpu(1.0)),
        ] {
            #expect(reading.count == 4, "\"\(reading)\" is not 4 characters wide")
        }
    }

    /// Never a zero or a guess: nothing measured, or no whole to be a
    /// fraction of, reads as the same em dash a tile shows.
    @Test("unmeasured, or memory without a total, is an em dash")
    func absenceIsAnEmDash() {
        #expect(MenuBarReadout.cpu(nil) == "—")
        #expect(MenuBarReadout.memory(nil, totalBytes: 16 << 30) == "—")
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: nil) == "—")
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: 0) == "—")
    }
}
