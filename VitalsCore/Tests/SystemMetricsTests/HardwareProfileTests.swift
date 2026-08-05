import Testing
@testable import SystemMetrics

@Suite("Hardware profile")
struct HardwareProfileTests {

    @Test("detects this machine's CPU and at least one GPU")
    func detectsThisMachine() throws {
        let profile = try HardwareProfile.detect()
        // `physicalCores` is `Int?` — absent sysctls read as nil, never 0.
        #expect(try #require(profile.cpu.physicalCores) > 0)
        #expect(profile.gpus.isEmpty == false)
        #expect(profile.memory.totalBytes > 0)
        #expect(profile.storageDevices.isEmpty == false)
        #expect(profile.storageDevices.allSatisfy { !$0.name.isEmpty })
    }

    @Test("Apple Silicon is reported as unified memory")
    func appleSiliconIsUnified() throws {
        let profile = try HardwareProfile.detect()
        if profile.cpu.isAppleSilicon {
            #expect(profile.memory.isUnified == true)
            #expect(profile.memory.speedMHz == nil)
        }
    }

    @Test("sensors report unavailable with a stated reason, not silently absent")
    func sensorsUnavailableWithReason() throws {
        // Injects the placeholder explicitly rather than relying on
        // `detect()`'s default: since Task 3 made `IOHIDSensorProvider` the
        // default, this machine's real sensors are `.available`, and calling
        // `detect()` bare would make this test assert on whatever hardware
        // happens to be running it rather than on the unavailable path this
        // test is named for.
        let profile = try HardwareProfile.detect(sensors: UnavailableSensorProvider())
        guard case .unavailable(let reason) = profile.sensorsAvailable else {
            Issue.record("Sensors should be unavailable when given the placeholder provider")
            return
        }
        #expect(reason.isEmpty == false)
    }

    @Test("the placeholder sensor provider yields no readings")
    func placeholderProviderYieldsNothing() {
        #expect(UnavailableSensorProvider().readings().isEmpty)
    }

    @Test("availability equates only when reasons match")
    func availabilityEquality() {
        #expect(MetricAvailability.available == MetricAvailability.available)
        #expect(MetricAvailability.unavailable(reason: "a") != .unavailable(reason: "b"))
    }
}
