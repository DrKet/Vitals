import Foundation
import Testing
@testable import MetricsEngine

@Suite("SamplingCadence staleness")
struct SamplingCadenceTests {

    @Test("Fast live threshold is exactly two cadence intervals")
    func fastThresholdIsTwoIntervals() {
        // Fast is 1 Hz; 2× means ~2s without a tick before a primary must
        // stop claiming currency. Derive from the cadence — never a bare 2.0.
        #expect(SamplingCadence.fast.interval == .seconds(1))
        #expect(SamplingCadence.stalenessCadenceMultiples == 2)
        #expect(SamplingCadence.fast.liveStalenessThreshold == .seconds(2))
        #expect(
            abs(SamplingCadence.fast.liveStalenessThreshold.timeInterval - 2.0) < 0.000_001
        )
    }

    @Test("a sample within one missed tick is still live")
    func withinOneMissedTickIsLive() {
        let cadence = SamplingCadence.fast
        let stamped: TimeInterval = 100
        // Exactly at the threshold remains live ("older than" is stale).
        #expect(cadence.isLive(sampleTimestamp: stamped, now: stamped + 2.0))
        #expect(cadence.isLive(sampleTimestamp: stamped, now: stamped + 1.5))
    }

    @Test("a sample older than two cadence intervals is stale")
    func olderThanTwoIntervalsIsStale() {
        let cadence = SamplingCadence.fast
        let stamped: TimeInterval = 100
        #expect(cadence.isLive(sampleTimestamp: stamped, now: stamped + 2.0 + 0.001) == false)
        #expect(cadence.isLive(sampleTimestamp: stamped, now: stamped + 3_600) == false)
    }

    @Test("Slow cadence scales the threshold with its own interval")
    func slowThresholdScales() {
        #expect(SamplingCadence.slow.interval == .seconds(5))
        #expect(SamplingCadence.slow.liveStalenessThreshold == .seconds(10))
    }
}
