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

    @Test("CPU reads as the Overview tile's whole percentage")
    func cpuPercentage() {
        #expect(MenuBarReadout.cpu(Self.cpu(0.234)) == "23%")
        #expect(MenuBarReadout.cpu(Self.cpu(1.0)) == "100%")
    }

    @Test("memory reads as used over total, as a whole percentage")
    func memoryPercentage() {
        let total: UInt64 = 16 << 30
        #expect(MenuBarReadout.memory(Self.memory(usedGiB: 4), totalBytes: total) == "25%")
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
