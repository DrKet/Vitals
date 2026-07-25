import Testing
@testable import SystemMetrics

@Suite("CPU load")
struct CPULoadTests {

    @Test("computes per-core fractions from tick deltas")
    func computesFractions() throws {
        let before = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0)]
        let after = [CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)]
        let sample = CPULoadCalculator.load(from: before, to: after)

        #expect(sample?.cores.count == 1)
        #expect(sample?.cores[0].user == 0.1)
        #expect(sample?.cores[0].system == 0.05)
        #expect(sample?.cores[0].idle == 0.85)
        // Compared with a tolerance: 0.1 + 0.05 is not exactly 0.15 in binary
        // floating point, and asserting the exact artefact would be brittle.
        let busy = try #require(sample?.cores[0].busy)
        #expect(abs(busy - 0.15) < 1e-9)
    }

    @Test("averages busy across cores for the total")
    func averagesTotal() {
        let before = [
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        ]
        let after = [
            CPUTicks(user: 100, system: 0, idle: 0, nice: 0),   // fully busy
            CPUTicks(user: 0, system: 0, idle: 100, nice: 0),   // fully idle
        ]
        #expect(CPULoadCalculator.load(from: before, to: after)?.total == 0.5)
    }

    @Test("counts nice time as busy")
    func niceCountsAsBusy() {
        let before = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [CPUTicks(user: 0, system: 0, idle: 50, nice: 50)]
        #expect(CPULoadCalculator.load(from: before, to: after)?.cores[0].busy == 0.5)
    }

    @Test("core count change invalidates the sample")
    func coreCountChangeInvalidates() {
        let before = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [
            CPUTicks(user: 100, system: 0, idle: 0, nice: 0),
            CPUTicks(user: 100, system: 0, idle: 0, nice: 0),
        ]
        #expect(CPULoadCalculator.load(from: before, to: after) == nil)
    }

    @Test("counter reset is dropped rather than reported as a spike")
    func counterResetIsDropped() {
        let before = [CPUTicks(user: 5000, system: 5000, idle: 5000, nice: 0)]
        let after = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]
        #expect(CPULoadCalculator.load(from: before, to: after) == nil)
    }

    @Test("an idle interval with no elapsed ticks reports fully idle")
    func noElapsedTicksIsIdle() {
        let ticks = [CPUTicks(user: 100, system: 100, idle: 100, nice: 0)]
        let sample = CPULoadCalculator.load(from: ticks, to: ticks)
        #expect(sample?.cores[0].busy == 0.0)
        #expect(sample?.cores[0].idle == 1.0)
    }

    @Test("empty input is rejected")
    func emptyInputRejected() {
        #expect(CPULoadCalculator.load(from: [], to: []) == nil)
    }

    @Test("groups core loads into named clusters")
    func groupsIntoClusters() {
        let sample = CPULoadSample(cores: [
            CoreLoad(user: 1.0, system: 0, idle: 0, nice: 0),  // P
            CoreLoad(user: 0.5, system: 0, idle: 0.5, nice: 0),  // P
            CoreLoad(user: 0, system: 0, idle: 1.0, nice: 0),  // E
            CoreLoad(user: 0, system: 0, idle: 1.0, nice: 0),  // E
        ])
        let clusters = [
            CPUCluster(name: "Performance", coreCount: 2, logicalCoreCount: 2),
            CPUCluster(name: "Efficiency", coreCount: 2, logicalCoreCount: 2),
        ]
        let loads = sample.clusterLoads(for: clusters)
        #expect(loads["Performance"] == 0.75)
        #expect(loads["Efficiency"] == 0.0)
    }

    @Test("live tick reader returns one entry per logical core")
    func liveReaderMatchesCoreCount() throws {
        let ticks = try #require(CPUTickReader.read())
        let topology = CPUTopology.detect(using: SystemSysctl())
        #expect(ticks.count == topology.logicalCores)
        #expect(ticks.allSatisfy { $0.total > 0 })
    }

    @Test("live system load reports a plausible uptime and load average")
    func liveSystemLoad() throws {
        let load = SystemLoad.current()
        #expect(load.uptimeSeconds > 0)
        let avg1 = try #require(load.loadAverage1)
        let avg15 = try #require(load.loadAverage15)
        #expect(avg1 >= 0)
        #expect(avg15 >= 0)
    }

    @Test("nil load averages are distinct from zero")
    func nilLoadAveragesDistinctFromZero() {
        // Construct with nil averages
        let nilLoad = SystemLoad(
            uptimeSeconds: 1000,
            loadAverage1: nil,
            loadAverage5: nil,
            loadAverage15: nil
        )
        #expect(nilLoad.loadAverage1 == nil)
        #expect(nilLoad.loadAverage5 == nil)
        #expect(nilLoad.loadAverage15 == nil)

        // Construct with zero averages
        let zeroLoad = SystemLoad(
            uptimeSeconds: 1000,
            loadAverage1: 0,
            loadAverage5: 0,
            loadAverage15: 0
        )
        #expect(zeroLoad.loadAverage1 == 0)
        #expect(zeroLoad.loadAverage5 == 0)
        #expect(zeroLoad.loadAverage15 == 0)

        // Verify they are not equal
        #expect(nilLoad != zeroLoad)
    }
}
