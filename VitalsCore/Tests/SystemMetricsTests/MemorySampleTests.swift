import Testing
@testable import SystemMetrics

@Suite("Memory sample")
struct MemorySampleTests {

    /// One page is 16 KiB on Apple Silicon.
    private static let page: UInt64 = 16384

    private func counters(
        free: UInt64 = 0,
        wired: UInt64 = 0,
        compressed: UInt64 = 0,
        purgeable: UInt64 = 0,
        external: UInt64 = 0,
        internalPages: UInt64 = 0
    ) -> VMCounters {
        VMCounters(
            free: free,
            wired: wired,
            compressed: compressed,
            purgeable: purgeable,
            external: external,
            internalPages: internalPages,
            pageSize: Self.page
        )
    }

    @Test("app memory excludes purgeable pages")
    func appExcludesPurgeable() {
        let sample = MemoryCalculator.sample(
            from: counters(purgeable: 200, internalPages: 1000),
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(sample.app == 800 * Self.page)
    }

    @Test("app memory is zero when purgeable exceeds internal pages")
    func appIsZeroWhenPurgeableExceedsInternal() {
        // The saturating-subtraction guard: without it, underflow would wrap
        // UInt64 and invent an enormous app-memory figure.
        let sample = MemoryCalculator.sample(
            from: counters(purgeable: 500, internalPages: 200),
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(sample.app == 0)
        #expect(sample.cached == 500 * Self.page)
    }

    @Test("used memory is app plus wired plus compressed")
    func usedIsAppPlusWiredPlusCompressed() {
        let sample = MemoryCalculator.sample(
            from: counters(wired: 100, compressed: 50, purgeable: 0, internalPages: 1000),
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(sample.used == 1150 * Self.page)
    }

    @Test("cached files are external plus purgeable pages")
    func cachedIsExternalPlusPurgeable() {
        let sample = MemoryCalculator.sample(
            from: counters(purgeable: 200, external: 300),
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(sample.cached == 500 * Self.page)
    }

    @Test("purgeable pages are never counted twice")
    func purgeableNotDoubleCounted() {
        let sample = MemoryCalculator.sample(
            from: counters(purgeable: 200, external: 300, internalPages: 1000),
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        // app (800) + cached (500) = 1300, not 1500
        #expect(sample.app + sample.cached == 1300 * Self.page)
    }

    @Test("swap is carried through unchanged")
    func swapCarriedThrough() {
        let sample = MemoryCalculator.sample(
            from: counters(),
            swapUsed: 1_073_741_824, swapTotal: 2_147_483_648, pressure: .warning
        )
        #expect(sample.swapUsed == 1_073_741_824)
        #expect(sample.swapTotal == 2_147_483_648)
        #expect(sample.pressure == .warning)
    }

    @Test("an unreadable swap or pressure value is nil, not a plausible default")
    func unreadableValuesAreNil() {
        let sample = MemoryCalculator.sample(
            from: counters(), swapUsed: nil, swapTotal: nil, pressure: nil
        )
        #expect(sample.swapUsed == nil)
        #expect(sample.swapTotal == nil)
        #expect(sample.pressure == nil)
    }

    @Test("zero swap is preserved as a real reading, distinct from nil")
    func zeroSwapIsNotNil() {
        let sample = MemoryCalculator.sample(
            from: counters(), swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(sample.swapUsed == 0)
        #expect(sample.swapUsed != nil)
    }

    @Test("live sampler reports plausible values for this machine")
    func liveSamplerIsPlausible() throws {
        let sample = try #require(MemorySampler.read())
        let installed = UInt64(SystemSysctl().integer("hw.memsize") ?? 0)
        #expect(sample.used > 0)
        #expect(sample.used < installed)
        #expect(sample.wired > 0)
    }
}
