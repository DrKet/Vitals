import Testing
@testable import SystemMetrics

@Suite("GPU sample")
struct GPUSampleTests {

    /// Captured verbatim from `ioreg -rc IOAccelerator -d1` on the M2 Pro.
    private let m2ProStatistics: [String: Any] = [
        "Device Utilization %": 22,
        "Renderer Utilization %": 21,
        "Tiler Utilization %": 22,
        "In use system memory": 221_315_072,
        "Alloc system memory": 13_907_378_176,
        "recoveryCount": 0,
        "SplitSceneCount": 0,
    ]

    @Test("parses utilisation as fractions in 0...1")
    func parsesUtilisation() throws {
        let sample = try #require(GPUStatisticsParser.parse(m2ProStatistics))
        #expect(sample.deviceUtilisation == 0.22)
        #expect(sample.rendererUtilisation == 0.21)
        #expect(sample.tilerUtilisation == 0.22)
    }

    @Test("parses memory figures in bytes")
    func parsesMemory() throws {
        let sample = try #require(GPUStatisticsParser.parse(m2ProStatistics))
        #expect(sample.inUseMemoryBytes == 221_315_072)
        #expect(sample.allocatedMemoryBytes == 13_907_378_176)
    }

    @Test("missing optional keys become nil, not zero")
    func missingKeysBecomeNil() throws {
        let sample = try #require(GPUStatisticsParser.parse(["Device Utilization %": 40]))
        #expect(sample.deviceUtilisation == 0.4)
        #expect(sample.rendererUtilisation == nil)
        #expect(sample.tilerUtilisation == nil)
        #expect(sample.inUseMemoryBytes == nil)
    }

    @Test("a dictionary with no recognised keys is rejected")
    func unrecognisedDictionaryRejected() {
        #expect(GPUStatisticsParser.parse(["recoveryCount": 0]) == nil)
    }

    @Test("utilisation above 100 is unreadable, not clamped to 100%")
    func utilisationAboveRangeIsNil() throws {
        let sample = try #require(GPUStatisticsParser.parse(["Device Utilization %": 140]))
        #expect(sample.deviceUtilisation == nil)
    }

    @Test("negative utilisation is unreadable, not clamped to 0%")
    func utilisationBelowRangeIsNil() throws {
        let sample = try #require(GPUStatisticsParser.parse(["Device Utilization %": -5]))
        #expect(sample.deviceUtilisation == nil)
    }

    @Test("live sampler finds at least one GPU on this machine")
    func liveSamplerFindsGPU() {
        #expect(GPUSampler.read().isEmpty == false)
    }

    @Test("this machine reports unified memory")
    func liveDeviceIsUnified() throws {
        let device = try #require(GPUSampler.devices().first)
        #expect(device.name.isEmpty == false)
        if case .unified = device.topology {
            // Expected on Apple Silicon.
        } else {
            Issue.record("Expected unified memory topology on Apple Silicon")
        }
    }
}
