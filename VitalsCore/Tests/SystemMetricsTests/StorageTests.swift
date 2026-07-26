import Testing
@testable import SystemMetrics

@Suite("Storage")
struct StorageTests {

    /// Shaped like the `IOBlockStorageDevice` properties on this machine's
    /// `APPLE SSD AP0512Z`.
    private let appleSSDCharacteristics: [String: Any] = [
        "Product Name": "APPLE SSD AP0512Z",
        "Medium Type": "Solid State",
        "Product Revision Level": "555",
    ]

    private let nvmeProtocol: [String: Any] = [
        "Physical Interconnect": "PCI-Express",
        "Physical Interconnect Location": "Internal",
    ]

    @Test("identifies solid state media")
    func identifiesSolidState() throws {
        let device = try #require(
            StorageDeviceParser.parse(
                deviceCharacteristics: appleSSDCharacteristics,
                protocolCharacteristics: nvmeProtocol
            )
        )
        #expect(device.name == "APPLE SSD AP0512Z")
        #expect(device.medium == .solidState)
        #expect(device.interconnect == "PCI-Express")
    }

    @Test("identifies rotational media")
    func identifiesRotational() throws {
        let device = try #require(
            StorageDeviceParser.parse(
                deviceCharacteristics: [
                    "Product Name": "ST2000DM008-2FR102",
                    "Medium Type": "Rotational",
                ],
                protocolCharacteristics: ["Physical Interconnect": "SATA"]
            )
        )
        #expect(device.medium == .rotational)
        #expect(device.interconnect == "SATA")
    }

    @Test("an unstated medium is unknown, not assumed to be an SSD")
    func unstatedMediumIsUnknown() throws {
        let device = try #require(
            StorageDeviceParser.parse(
                deviceCharacteristics: ["Product Name": "Generic USB Disk"],
                protocolCharacteristics: [:]
            )
        )
        #expect(device.medium == .unknown)
        #expect(device.interconnect == nil)
    }

    @Test("a device with no product name is rejected")
    func namelessDeviceRejected() {
        #expect(
            StorageDeviceParser.parse(
                deviceCharacteristics: [:],
                protocolCharacteristics: [:]
            ) == nil
        )
    }

    @Test("used fraction is computed from total and available")
    func usedFraction() {
        let volume = Volume(
            name: "Macintosh HD",
            totalBytes: 1000,
            availableBytes: 250,
            isInternal: true
        )
        #expect(volume.usedFraction == 0.75)
    }

    @Test("a zero-capacity volume reports zero used rather than dividing by zero")
    func zeroCapacityVolume() {
        let volume = Volume(name: "Empty", totalBytes: 0, availableBytes: 0, isInternal: false)
        #expect(volume.usedFraction == 0)
    }

    @Test("live volume enumeration finds the boot volume")
    func liveVolumesFindBootVolume() {
        let volumes = StorageSampler.volumes()
        #expect(volumes.isEmpty == false)
        #expect(volumes.contains { $0.isInternal && $0.totalBytes > 0 })
    }

    @Test("no IO counter is filed under a placeholder device name")
    func noPlaceholderDeviceKeys() {
        // A driver with no discoverable BSD name must be omitted, not filed
        // under a shared placeholder — two such drivers would collide, and
        // successive samples could key different devices identically.
        let devices = StorageSampler.ioCounters().keys
        #expect(devices.contains("unknown") == false)
        #expect(devices.allSatisfy { $0.isEmpty == false })
    }

    @Test("live IO counters are non-empty and monotonic across two reads")
    func liveIOCountersAreMonotonic() {
        let first = StorageSampler.ioCounters()
        #expect(first.isEmpty == false)

        let second = StorageSampler.ioCounters()
        for (device, before) in first {
            guard let after = second[device] else { continue }
            #expect(after.bytesRead >= before.bytesRead)
            #expect(after.bytesWritten >= before.bytesWritten)
        }
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
