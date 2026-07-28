import Foundation
import Testing
@testable import MetricsEngine

@Suite("Live staleness threshold")
struct SamplingCadenceTests {

    private let fast = SamplingCadence.fast.interval
    private let slow = SamplingCadence.slow.interval

    @Test("the fast cadence's threshold is the floor, not two of its intervals")
    func fastThresholdIsTheFloor() {
        // Fast is 1 Hz, so a bare 2x multiple would be 2s. `MetricsStore` is
        // @MainActor, and this project measured concurrent window renders
        // starving a main-actor poll loop for over two seconds — at 2s the
        // largest number on screen would blank during a window resize and come
        // back a moment later. The floor is what prevents that.
        #expect(fast == .seconds(1))
        #expect(LiveStaleness.intervalMultiple == 2)
        #expect(LiveStaleness.floor == .seconds(10))
        #expect(LiveStaleness.threshold(forInterval: fast) == .seconds(10))
        #expect(abs(LiveStaleness.threshold(forInterval: fast).timeInterval - 10.0) < 0.000_001)
    }

    @Test("a sample well inside the threshold is still live")
    func withinThresholdIsLive() {
        let stamped: TimeInterval = 100
        // Exactly at the threshold remains live ("older than" is stale).
        #expect(LiveStaleness.isLive(sampleTimestamp: stamped, now: stamped + 10.0, interval: fast))
        #expect(LiveStaleness.isLive(sampleTimestamp: stamped, now: stamped + 1.5, interval: fast))
        // The case the floor exists for: a tick delayed several seconds by a
        // busy main actor must not expire the reading.
        #expect(LiveStaleness.isLive(sampleTimestamp: stamped, now: stamped + 4.0, interval: fast))
    }

    @Test("a sample past the threshold is stale, and an hour old certainly is")
    func pastThresholdIsStale() {
        let stamped: TimeInterval = 100
        #expect(
            LiveStaleness.isLive(sampleTimestamp: stamped, now: stamped + 10.001, interval: fast)
                == false
        )
        // The behaviour this whole gate exists for.
        #expect(
            LiveStaleness.isLive(sampleTimestamp: stamped, now: stamped + 3_600, interval: fast)
                == false
        )
    }

    @Test("an interval slower than the floor scales past it instead of being clamped")
    func slowIntervalScalesAboveTheFloor() {
        // The floor is a minimum, not a fixed value: a series sampled every
        // 30s must not be called stale 10s after its last tick, which would
        // expire it for two thirds of every sampling period.
        #expect(slow == .seconds(5))
        #expect(LiveStaleness.threshold(forInterval: slow) == .seconds(10))
        #expect(LiveStaleness.threshold(forInterval: .seconds(30)) == .seconds(60))
        #expect(LiveStaleness.threshold(forInterval: .seconds(60)) == .seconds(120))
    }
}
