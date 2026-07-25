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
        let profile = try HardwareProfile.detect()
        guard case .unavailable(let reason) = profile.sensorsAvailable else {
            Issue.record("Sensors should be unavailable until IOReport lands")
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
