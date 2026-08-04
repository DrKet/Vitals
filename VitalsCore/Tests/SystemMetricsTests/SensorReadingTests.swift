import Foundation
import Testing
@testable import SystemMetrics

@Suite("Sensor model")
struct SensorReadingTests {

    /// `sensorCount` exists because the spike proved sensors have no unique
    /// identity: 28 of 64 temperature sensors collide even on
    /// `Product`+`LocationID`. An aggregated reading must therefore say how
    /// many sensors stand behind it.
    @Test("a reading carries how many sensors reported it")
    func readingCarriesSensorCount() {
        let reading = SensorReading(
            name: "PMU tdie1", kind: .temperatureCelsius, value: 38.8, sensorCount: 4
        )
        #expect(reading.sensorCount == 4)
        #expect(abs(reading.value - 38.8) < 1e-9)
    }

    @Test("a sample carries the machine's thermal state alongside its readings")
    func sampleCarriesThermalState() {
        let sample = SensorSample(
            readings: [SensorReading(name: "PMU tdie0", kind: .temperatureCelsius, value: 36.0, sensorCount: 2)],
            thermalState: .nominal
        )
        #expect(sample.readings.count == 1)
        #expect(sample.thermalState == .nominal)
    }
}
