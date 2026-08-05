import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Sensors page")
struct SensorsPageTests {

    private static nonisolated func sample() -> SensorSample {
        SensorSample(
            readings: [
                SensorReading(name: "PMU tdie0", kind: .temperatureCelsius, value: 36.5, sensorCount: 2),
                SensorReading(name: "PMU tdie1", kind: .temperatureCelsius, value: 38.8, sensorCount: 4),
                SensorReading(name: "PMU tcal", kind: .temperatureCelsius, value: 51.85, sensorCount: 2),
                SensorReading(name: "gas gauge battery", kind: .temperatureCelsius, value: 28.7, sensorCount: 6),
                SensorReading(name: "NAND CH0 temp", kind: .temperatureCelsius, value: 30.0, sensorCount: 1),
            ],
            thermalState: .nominal
        )
    }

    /// tcal reads hotter than every die sensor and must NOT become the
    /// headline: the headline is the hottest die, and tcal is not a die sensor.
    @Test("the headline is the hottest die, not the hottest sensor")
    func headlineIsHottestDie() {
        #expect(SensorsPage.hottestDie(in: Self.sample()) == 38.8)
    }

    @Test("die average covers only the die sensors")
    func dieAverageCoversOnlyDies() throws {
        let average = try #require(SensorsPage.dieAverage(in: Self.sample()))
        #expect(abs(average - 37.65) < 1e-9)
    }

    @Test("a sample with no die sensors yields no headline, never a zero")
    func noDieSensorsYieldsNil() {
        let sample = SensorSample(
            readings: [SensorReading(name: "gas gauge battery", kind: .temperatureCelsius, value: 28.7, sensorCount: 6)],
            thermalState: .nominal
        )
        #expect(SensorsPage.hottestDie(in: sample) == nil)
        #expect(SensorsPage.dieAverage(in: sample) == nil)
    }

    @Test("only verifiable sensors get friendly names")
    func namingIsConservative() {
        #expect(SensorsPage.displayName(for: "gas gauge battery") == "Battery")
        #expect(SensorsPage.displayName(for: "NAND CH0 temp") == "Storage (NAND)")
        // Unverifiable ones keep their raw strings — see the naming rules.
        #expect(SensorsPage.displayName(for: "PMU tdie0") == "PMU tdie0")
        #expect(SensorsPage.displayName(for: "PMU TP1g") == "PMU TP1g")
    }

    @Test("readings group by family so tcal cannot read as a contradiction")
    func groupsByFamily() {
        let groups = SensorsPage.grouped(Self.sample().readings)
        #expect(groups.first(where: { $0.title == "Die" })?.readings.count == 2)
        #expect(groups.first(where: { $0.title == "Battery" })?.readings.count == 1)
        // tcal is neither a die nor a device sensor.
        #expect(groups.first(where: { $0.title == "Die" })?.readings.contains { $0.name == "PMU tcal" } == false)
    }

    /// Apple's four-level scale rendered plainly. Uncoloured deliberately:
    /// colouring "Fair" amber would assert a severity judgement the scale does
    /// not carry, and `Palette.warning` is reserved.
    @Test("thermal state renders as its plain name")
    func thermalStateRendersPlainly() {
        #expect(SensorsPage.thermalStateName(.nominal) == "Nominal")
        #expect(SensorsPage.thermalStateName(.fair) == "Fair")
        #expect(SensorsPage.thermalStateName(.serious) == "Serious")
        #expect(SensorsPage.thermalStateName(.critical) == "Critical")
    }
}
