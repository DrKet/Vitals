import Foundation
import SystemMetrics
import Testing
@testable import MetricsEngine

@Suite("Disk IO")
struct DiskIOSamplerTests {

    @Test("diskIO is one of the standard series")
    func diskIOIsAStandardSeries() {
        #expect(SeriesKey.allCases.contains(.diskIO))
    }

    @Test("the first reading yields no throughput, because there is nothing to subtract from")
    func firstReadingYieldsNothing() {
        var tracker = DiskThroughputTracker()
        let counters = ["disk0": StorageIOCounters(bytesRead: 1000, bytesWritten: 500)]
        #expect(tracker.update(counters, at: 10).isEmpty)
    }

    @Test("the second reading yields per-second rates")
    func secondReadingYieldsRates() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk0": StorageIOCounters(bytesRead: 1000, bytesWritten: 500)], at: 10)
        let result = tracker.update(["disk0": StorageIOCounters(bytesRead: 3000, bytesWritten: 1500)], at: 12)

        #expect(result["disk0"]?.bytesReadPerSecond == 1000)
        #expect(result["disk0"]?.bytesWrittenPerSecond == 500)
    }

    @Test("devices are tracked independently")
    func devicesTrackedIndependently() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update([
            "disk0": StorageIOCounters(bytesRead: 0, bytesWritten: 0),
            "disk4": StorageIOCounters(bytesRead: 0, bytesWritten: 0),
        ], at: 10)
        let result = tracker.update([
            "disk0": StorageIOCounters(bytesRead: 100, bytesWritten: 0),
            "disk4": StorageIOCounters(bytesRead: 900, bytesWritten: 0),
        ], at: 11)

        #expect(result["disk0"]?.bytesReadPerSecond == 100)
        #expect(result["disk4"]?.bytesReadPerSecond == 900)
    }

    @Test("a device appearing mid-stream produces no rate on its first sample")
    func appearingDeviceHasNoRate() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk0": StorageIOCounters(bytesRead: 0, bytesWritten: 0)], at: 10)
        let result = tracker.update([
            "disk0": StorageIOCounters(bytesRead: 100, bytesWritten: 0),
            "disk9": StorageIOCounters(bytesRead: 5000, bytesWritten: 0),
        ], at: 11)

        #expect(result["disk0"] != nil)
        #expect(result["disk9"] == nil)
    }

    @Test("a counter reset is dropped rather than reported as a burst")
    func counterResetIsDropped() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk0": StorageIOCounters(bytesRead: 9_000_000, bytesWritten: 0)], at: 10)
        let result = tracker.update(["disk0": StorageIOCounters(bytesRead: 40, bytesWritten: 0)], at: 11)
        #expect(result["disk0"] == nil)
    }

    @Test("a device that goes away is forgotten, so a later return starts fresh")
    func departedDeviceIsForgotten() {
        var tracker = DiskThroughputTracker()
        _ = tracker.update(["disk4": StorageIOCounters(bytesRead: 9000, bytesWritten: 0)], at: 10)
        _ = tracker.update([:], at: 11)
        let result = tracker.update(["disk4": StorageIOCounters(bytesRead: 20, bytesWritten: 0)], at: 12)

        // Without forgetting, this would report a huge negative-turned-dropped
        // delta against a stale reading from before the device was unplugged.
        #expect(result["disk4"] == nil)
    }
}
