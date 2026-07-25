import Testing
@testable import SystemMetrics

@Suite("Network")
struct NetworkTests {

    private func counters(_ name: String, in bytesIn: UInt64, out bytesOut: UInt64) -> InterfaceCounters {
        InterfaceCounters(
            name: name, bytesIn: bytesIn, bytesOut: bytesOut,
            packetsIn: 0, packetsOut: 0, errorsIn: 0, errorsOut: 0
        )
    }

    @Test("first update yields no throughput")
    func firstUpdateYieldsNothing() {
        var tracker = NetworkThroughputTracker()
        let result = tracker.update([counters("en0", in: 1000, out: 500)], at: 10.0)
        #expect(result.isEmpty)
    }

    @Test("second update yields per-second rates")
    func secondUpdateYieldsRates() {
        var tracker = NetworkThroughputTracker()
        _ = tracker.update([counters("en0", in: 1000, out: 500)], at: 10.0)
        let result = tracker.update([counters("en0", in: 3000, out: 1500)], at: 12.0)

        #expect(result["en0"]?.bytesInPerSecond == 1000)
        #expect(result["en0"]?.bytesOutPerSecond == 500)
    }

    @Test("interfaces are tracked independently")
    func interfacesTrackedIndependently() {
        var tracker = NetworkThroughputTracker()
        _ = tracker.update(
            [counters("en0", in: 0, out: 0), counters("utun0", in: 0, out: 0)], at: 10.0
        )
        let result = tracker.update(
            [counters("en0", in: 100, out: 0), counters("utun0", in: 900, out: 0)], at: 11.0
        )
        #expect(result["en0"]?.bytesInPerSecond == 100)
        #expect(result["utun0"]?.bytesInPerSecond == 900)
    }

    @Test("an interface appearing mid-stream produces no rate on its first sample")
    func appearingInterfaceHasNoRate() {
        var tracker = NetworkThroughputTracker()
        _ = tracker.update([counters("en0", in: 0, out: 0)], at: 10.0)
        let result = tracker.update(
            [counters("en0", in: 100, out: 0), counters("utun5", in: 5000, out: 0)], at: 11.0
        )
        #expect(result["en0"]?.bytesInPerSecond == 100)
        #expect(result["utun5"] == nil)
    }

    @Test("a counter reset is dropped rather than reported as a burst")
    func counterResetDropped() {
        var tracker = NetworkThroughputTracker()
        _ = tracker.update([counters("en0", in: 9_000_000, out: 0)], at: 10.0)
        let result = tracker.update([counters("en0", in: 40, out: 0)], at: 11.0)
        #expect(result["en0"] == nil)
    }

    @Test("live counters include the loopback interface")
    func liveCountersIncludeLoopback() {
        let interfaces = NetworkSampler.counters()
        #expect(interfaces.isEmpty == false)
        #expect(interfaces.contains { $0.name == "lo0" })
    }
}
