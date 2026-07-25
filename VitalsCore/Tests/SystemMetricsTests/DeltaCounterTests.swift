import Testing
@testable import SystemMetrics

@Suite("DeltaCounter")
struct DeltaCounterTests {

    @Test("first sample produces no rate")
    func firstSampleIsDiscarded() {
        var counter = DeltaCounter<UInt64>()
        #expect(counter.update(1000, at: 10.0) == nil)
    }

    @Test("second sample produces the rate")
    func secondSampleProducesRate() {
        var counter = DeltaCounter<UInt64>()
        _ = counter.update(1000, at: 10.0)
        let delta = counter.update(1500, at: 12.0)
        #expect(delta?.amount == 500)
        #expect(delta?.interval == 2.0)
        #expect(delta?.perSecond == 250.0)
    }

    @Test("counter wraparound is dropped, not reported as a spike")
    func wraparoundIsDropped() {
        var counter = DeltaCounter<UInt64>()
        _ = counter.update(9_000_000, at: 10.0)
        #expect(counter.update(12, at: 11.0) == nil)
    }

    @Test("recovers on the sample after a wraparound")
    func recoversAfterWraparound() {
        var counter = DeltaCounter<UInt64>()
        _ = counter.update(9_000_000, at: 10.0)
        _ = counter.update(12, at: 11.0)
        let delta = counter.update(112, at: 12.0)
        #expect(delta?.amount == 100)
    }

    @Test("non-monotonic timestamp is dropped")
    func nonMonotonicTimestampIsDropped() {
        var counter = DeltaCounter<UInt64>()
        _ = counter.update(1000, at: 10.0)
        #expect(counter.update(1500, at: 9.0) == nil)
    }

    @Test("zero interval is dropped rather than dividing by zero")
    func zeroIntervalIsDropped() {
        var counter = DeltaCounter<UInt64>()
        _ = counter.update(1000, at: 10.0)
        #expect(counter.update(1500, at: 10.0) == nil)
    }

    @Test("reset discards history so the next sample produces no rate")
    func resetDiscardsHistory() {
        var counter = DeltaCounter<UInt64>()
        _ = counter.update(1000, at: 10.0)
        counter.reset()
        #expect(counter.update(1500, at: 12.0) == nil)
    }
}
