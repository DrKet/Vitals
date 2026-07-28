import Testing
@testable import SystemMetrics

/// Replays recorded sysctl values so topology parsing is testable off-device.
struct StubSysctl: SysctlProviding {
    var integers: [String: Int64] = [:]
    var strings: [String: String] = [:]

    func integer(_ name: String) -> Int64? { integers[name] }
    func string(_ name: String) -> String? { strings[name] }
}

extension StubSysctl {
    /// Values captured from the M2 Pro development machine.
    static let appleSiliconM2Pro = StubSysctl(
        integers: [
            "hw.nperflevels": 2,
            "hw.physicalcpu": 10,
            "hw.logicalcpu": 10,
            "hw.perflevel0.physicalcpu": 6,
            "hw.perflevel0.logicalcpu": 6,
            "hw.perflevel1.physicalcpu": 4,
            "hw.perflevel1.logicalcpu": 4,
            "hw.l1dcachesize": 65536,
            "hw.l2cachesize": 4_194_304,
            // hw.l3cachesize deliberately absent — it does not exist on Apple Silicon
        ],
        strings: [
            "machdep.cpu.brand_string": "Apple M2 Pro",
            "hw.perflevel0.name": "Performance",
            "hw.perflevel1.name": "Efficiency",
        ]
    )

    /// A representative Intel machine: no perflevels, but an L3 cache.
    static let intelCoreI9 = StubSysctl(
        integers: [
            "hw.physicalcpu": 8,
            "hw.logicalcpu": 16,
            "hw.l1dcachesize": 32768,
            "hw.l2cachesize": 262_144,
            "hw.l3cachesize": 16_777_216,
        ],
        strings: [
            "machdep.cpu.brand_string": "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz",
        ]
    )
}

@Suite("CPUTopology")
struct CPUTopologyTests {

    @Test("parses Apple Silicon performance and efficiency clusters")
    func parsesAppleSiliconClusters() {
        let topology = CPUTopology.detect(using: StubSysctl.appleSiliconM2Pro)
        #expect(topology.brand == "Apple M2 Pro")
        #expect(topology.physicalCores == 10)
        #expect(topology.clusters.count == 2)
        #expect(topology.clusters[0].name == "Performance")
        #expect(topology.clusters[0].coreCount == 6)
        #expect(topology.clusters[1].name == "Efficiency")
        #expect(topology.clusters[1].coreCount == 4)
        #expect(topology.isAppleSilicon == true)
    }

    @Test("reports absent L3 cache as nil rather than zero")
    func absentL3IsNil() {
        let topology = CPUTopology.detect(using: StubSysctl.appleSiliconM2Pro)
        #expect(topology.l3CacheBytes == nil)
        #expect(topology.l2CacheBytes == 4_194_304)
    }

    @Test("parses L1 data cache size from hw.l1dcachesize")
    func parsesL1DataCache() {
        let apple = CPUTopology.detect(using: StubSysctl.appleSiliconM2Pro)
        #expect(apple.l1DataCacheBytes == 65536)

        let intel = CPUTopology.detect(using: StubSysctl.intelCoreI9)
        #expect(intel.l1DataCacheBytes == 32768)
    }

    @Test("reports absent L1 data cache as nil rather than zero")
    func absentL1DataCacheIsNil() {
        let stubSysctl = StubSysctl(
            integers: [
                "hw.physicalcpu": 4,
                "hw.logicalcpu": 4,
            ],
            strings: ["machdep.cpu.brand_string": "Unknown Processor"]
        )
        let topology = CPUTopology.detect(using: stubSysctl)
        #expect(topology.l1DataCacheBytes == nil)
    }

    @Test("a perflevel with partial data is silently dropped")
    func partialPerflevelIsSilentlyDropped() {
        // nperflevels claims two levels, but level 1 is missing physicalcpu.
        // The loop continues rather than throwing or inventing a cluster — the
        // incomplete level simply never appears.
        let stubSysctl = StubSysctl(
            integers: [
                "hw.nperflevels": 2,
                "hw.physicalcpu": 10,
                "hw.logicalcpu": 10,
                "hw.perflevel0.physicalcpu": 6,
                "hw.perflevel0.logicalcpu": 6,
                // hw.perflevel1.physicalcpu deliberately absent
            ],
            strings: [
                "machdep.cpu.brand_string": "Apple M2 Pro",
                "hw.perflevel0.name": "Performance",
                "hw.perflevel1.name": "Efficiency",
            ]
        )
        let topology = CPUTopology.detect(using: stubSysctl)
        #expect(topology.clusters.count == 1)
        #expect(topology.clusters[0].name == "Performance")
        #expect(topology.clusters[0].coreCount == 6)
    }

    @Test("reports absent core counts as nil rather than zero")
    func absentCoreCountsAreNil() {
        let stubSysctl = StubSysctl(
            integers: [:],
            strings: ["machdep.cpu.brand_string": "Unknown Processor"]
        )
        let topology = CPUTopology.detect(using: stubSysctl)
        #expect(topology.physicalCores == nil)
        #expect(topology.logicalCores == nil)
    }

    @Test("parses Intel topology with no clusters and a real L3")
    func parsesIntel() {
        let topology = CPUTopology.detect(using: StubSysctl.intelCoreI9)
        #expect(topology.clusters.isEmpty)
        #expect(topology.isAppleSilicon == false)
        #expect(topology.logicalCores == 16)
        #expect(topology.l3CacheBytes == 16_777_216)
    }

    @Test("frequency is reported unavailable until IOReport lands")
    func frequencyUnavailable() {
        let topology = CPUTopology.detect(using: StubSysctl.appleSiliconM2Pro)
        #expect(topology.frequencyAvailable == false)
    }

    @Test("live detection matches the running machine")
    func liveDetection() throws {
        let topology = CPUTopology.detect(using: SystemSysctl())
        let physicalCores = try #require(topology.physicalCores)
        let logicalCores = try #require(topology.logicalCores)
        #expect(physicalCores > 0)
        #expect(logicalCores >= physicalCores)
        #expect(topology.brand.isEmpty == false)
    }
}
