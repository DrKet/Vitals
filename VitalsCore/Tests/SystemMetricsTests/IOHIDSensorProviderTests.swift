import Foundation
import Testing
@testable import SystemMetrics

@Suite("IOHID sensor provider")
struct IOHIDSensorProviderTests {

    /// The rule from the spike: group by name, take the MAX, count instances.
    /// Max rather than mean because a thermal readout is about the hottest
    /// point and a mean would understate it.
    @Test("duplicate names collapse to one reading carrying the hottest value")
    func aggregatesDuplicatesByMax() {
        let readings = IOHIDSensorProvider.aggregate([
            (name: "PMU tdie1", celsius: 36.0),
            (name: "PMU tdie1", celsius: 38.5),
            (name: "PMU tdie1", celsius: 37.2),
            (name: "gas gauge battery", celsius: 28.7),
        ])

        #expect(readings.count == 2)
        let die = try! #require(readings.first { $0.name == "PMU tdie1" })
        #expect(abs(die.value - 38.5) < 1e-9)
        #expect(die.sensorCount == 3)

        let battery = try! #require(readings.first { $0.name == "gas gauge battery" })
        #expect(abs(battery.value - 28.7) < 1e-9)
        #expect(battery.sensorCount == 1)
    }

    @Test("every aggregated reading is a temperature")
    func aggregatesAsTemperatures() {
        let readings = IOHIDSensorProvider.aggregate([(name: "NAND CH0 temp", celsius: 30)])
        #expect(readings.allSatisfy { $0.kind == .temperatureCelsius })
    }

    /// Deterministic order, so a render test's rows cannot reshuffle between
    /// runs and so the page's Full specifications list is stable.
    @Test("aggregated readings come back in a stable order")
    func aggregatesInStableOrder() {
        let input = [(name: "PMU tdie2", celsius: 1.0), (name: "PMU tdie1", celsius: 2.0), (name: "AAA", celsius: 3.0)]
        #expect(IOHIDSensorProvider.aggregate(input).map(\.name) == ["AAA", "PMU tdie1", "PMU tdie2"])
    }

    @Test("no input yields no readings, never a zero reading")
    func aggregatesEmpty() {
        #expect(IOHIDSensorProvider.aggregate([]).isEmpty)
    }

    /// Not a correctness assertion about any particular value — it cannot be,
    /// because sensor names and counts differ per Mac model. It asserts the
    /// provider is internally consistent with itself on whatever machine runs
    /// it: if it says it is available, it must produce readings, and every one
    /// must be finite and carry at least one sensor.
    @Test("on hardware that reports sensors, every reading is finite and counted")
    func liveReadingsAreSelfConsistent() {
        let provider = IOHIDSensorProvider()
        guard provider.availability.isAvailable else { return }
        let readings = provider.readings()
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { $0.value.isFinite })
        #expect(readings.allSatisfy { $0.sensorCount >= 1 })
        #expect(readings.allSatisfy { !$0.name.isEmpty })
    }
}
