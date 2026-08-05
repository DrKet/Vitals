import Foundation
import SwiftUI
import SystemMetrics

/// One family of readings in Full specifications — see `SensorsPage.grouped(_:)`.
///
/// Grouping exists so `PMU tcal` (~51.9 °C, hotter than any die sensor) never
/// sits in a flat list under a headline reporting a cooler die temperature.
/// Read in isolation that looks like the headline is wrong; grouped by family
/// it reads as what it is — a different kind of sensor entirely.
public struct SensorGroup: Equatable {
    public let title: String
    public let readings: [SensorReading]
}

public struct SensorsPage: View {
    /// Exposed so `PageConsistencyTests` can verify no two pages share a key —
    /// a shared key would make one page's disclosure expand every other's.
    public static let disclosureKey = "SensorsPage.showFullSpecifications"

    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// The spike (docs/superpowers/spikes/2026-08-02-sensors-spike.md) found
    /// no way to verify which physical component a PMU sensor belongs to.
    /// `tdie`/`tdev`/`TP`-prefixed names are kept as the raw strings the PMU
    /// reports rather than relabelled "CPU"/"GPU" — attributing a real
    /// reading to hardware that was never verified is the same class of
    /// error as inventing the reading outright.
    private static let diePrefix = "PMU tdie"
    private static let devicePrefix = "PMU tdev"
    private static let thermalPressurePrefix = "PMU TP"

    /// The only two sensor names the spike could identify with confidence.
    private static let batteryName = "gas gauge battery"
    private static let storageName = "NAND CH0 temp"

    /// The families Full specifications groups readings into, in display
    /// order. `tcal` and anything else unrecognised falls into `.other` —
    /// never annotated as a calibration constant, since that would be an
    /// inference from one spike on one machine rather than something
    /// established.
    private enum Family: CaseIterable {
        case die, device, thermalPressure, battery, storage, other

        var title: String {
            switch self {
            case .die: "Die"
            case .device: "Device"
            case .thermalPressure: "Thermal pressure"
            case .battery: "Battery"
            case .storage: "Storage"
            case .other: "Other"
            }
        }
    }

    private static func family(for name: String) -> Family {
        if name.hasPrefix(diePrefix) { return .die }
        if name.hasPrefix(devicePrefix) { return .device }
        if name.hasPrefix(thermalPressurePrefix) { return .thermalPressure }
        if name == batteryName { return .battery }
        if name == storageName { return .storage }
        return .other
    }

    /// Readings grouped by family for Full specifications. A family with no
    /// readings this tick is omitted rather than shown empty.
    public static func grouped(_ readings: [SensorReading]) -> [SensorGroup] {
        Family.allCases.compactMap { family in
            let matches = readings.filter { Self.family(for: $0.name) == family }
            guard !matches.isEmpty else { return nil }
            return SensorGroup(title: family.title, readings: matches)
        }
    }

    /// `gas gauge battery` and `NAND CH0 temp` are the only two names the
    /// spike could verify with confidence, so only those two get friendlier
    /// names. Everything else — every `tdie`/`tdev`/`TP` PMU string — keeps
    /// its raw name verbatim: renaming an unverified sensor to "CPU" or "GPU"
    /// would assert an attribution the spike never established.
    public static func displayName(for name: String) -> String {
        switch name {
        case batteryName: "Battery"
        case storageName: "Storage (NAND)"
        default: name
        }
    }

    /// The die sensors specifically — the readings `PMU tdie` selects. If
    /// Apple ever renames these, this selects nothing, `hottestDie`/`dieAverage`
    /// both become `nil`, and the headline renders as an em dash. That is the
    /// correct outcome: a silent fallback to some other sensor would misattribute
    /// a reading to the die.
    private static func dieReadings(in sample: SensorSample) -> [SensorReading] {
        sample.readings.filter { $0.name.hasPrefix(diePrefix) }
    }

    /// The hottest die reading itself, so the "hottest sensor" stat can name
    /// which raw PMU string produced the headline value.
    private static func hottestDieReading(in sample: SensorSample) -> SensorReading? {
        dieReadings(in: sample).max { $0.value < $1.value }
    }

    /// The page's headline: the hottest *die* temperature, never the hottest
    /// sensor overall. `PMU tcal` reads hotter than any die sensor on the
    /// machine the spike measured, and it is not a die sensor — see
    /// `SensorGroup`'s doc comment.
    public static func hottestDie(in sample: SensorSample) -> Double? {
        hottestDieReading(in: sample)?.value
    }

    /// Average across die sensors only — `tcal` and every other family are
    /// excluded, for the same reason `hottestDie` excludes them.
    public static func dieAverage(in sample: SensorSample) -> Double? {
        let values = dieReadings(in: sample).map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func reading(named name: String, in readings: [SensorReading]) -> Double? {
        readings.first { $0.name == name }?.value
    }

    /// Apple's four-level thermal scale, rendered as its plain name.
    /// Deliberately uncoloured: `Palette.warning` is reserved, and colouring
    /// "Fair" amber would assert a severity judgement the scale itself does
    /// not carry.
    public static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// A reading's value formatted per its own kind — only `.temperatureCelsius`
    /// is produced today, but `SensorReading.Kind` also models fan and power
    /// readings for whenever a provider exists for them, and formatting every
    /// kind as a temperature would misrepresent one the moment it arrives.
    private static func formattedValue(_ reading: SensorReading) -> String {
        switch reading.kind {
        case .temperatureCelsius: ChartUnit.temperature.formatted(reading.value)
        case .fanRPM: "\(Int(reading.value.rounded())) RPM"
        case .powerWatts: String(format: "%.2f W", reading.value)
        }
    }

    /// Die, Battery, Storage bands, in that order — the first is the base
    /// band `MetricChart` paints frontmost and marks with the live dot.
    /// Unstacked: temperatures never sum, so summing a 38 °C die with a 28 °C
    /// battery would draw a 66 °C band no sensor ever reported.
    ///
    /// Follows the all-or-nothing rule `GPUPage.allOrNothingBand` and
    /// `CPUPage.clusterSeries` already use: a band missing even one tick's
    /// reading is dropped entirely rather than gapped, since a partial band
    /// would imply a measurement the sensor never actually reported for the
    /// ticks it's missing.
    public static func series(history: [Timestamped<SensorSample>]) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        let timestamps = history.map(\.timestamp)

        return [
            band(name: "Die", history: history, timestamps: timestamps) { hottestDie(in: $0) },
            band(name: "Battery", history: history, timestamps: timestamps) { reading(named: batteryName, in: $0.readings) },
            band(name: "Storage", history: history, timestamps: timestamps) { reading(named: storageName, in: $0.readings) },
        ].compactMap { $0 }
    }

    private static func band(
        name: String,
        history: [Timestamped<SensorSample>],
        timestamps: [TimeInterval],
        value: (SensorSample) -> Double?
    ) -> ChartSeries? {
        let values = history.compactMap { value($0.sample) }
        guard values.count == history.count else { return nil }
        return ChartSeries(name: name, values: values, timestamps: timestamps, unit: .temperature)
    }

    // MARK: View

    private var hottestDieValue: Double? {
        store.sensors.flatMap(Self.hottestDie)
    }

    public var body: some View {
        HardwarePage(
            title: "Sensors",
            // No single device to name — as Network's header does, per its
            // own doc comment: 64 sensors with no unique identity is not a
            // vendor mark.
            vendorName: nil,
            showsAppleMark: false,
            primaryValue: hottestDieValue.map { ChartUnit.temperature.formatted($0) },
            series: Self.series(history: store.sensorHistory),
            accent: Vitals.Palette.sensors,
            stacked: false,
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            ThermometerStrip(celsius: hottestDieValue)
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.sensors) }
    }

    private var stats: [HardwareStat] {
        let sample = store.sensors
        return [
            HardwareStat(
                label: "Die average",
                value: sample.flatMap(Self.dieAverage).map { ChartUnit.temperature.formatted($0) }
            ),
            HardwareStat(
                label: "Hottest sensor",
                value: sample.flatMap(Self.hottestDieReading).map { Self.displayName(for: $0.name) }
            ),
            HardwareStat(
                label: "Battery",
                value: sample.flatMap { Self.reading(named: Self.batteryName, in: $0.readings) }
                    .map { ChartUnit.temperature.formatted($0) }
            ),
            HardwareStat(
                label: "Storage",
                value: sample.flatMap { Self.reading(named: Self.storageName, in: $0.readings) }
                    .map { ChartUnit.temperature.formatted($0) }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        // Machine-level, not per-sensor, so it does not belong among the four
        // key stats above — but it is the only severity signal in this
        // design, and collecting it in `SensorSample` without ever showing it
        // would ship a field nothing reads.
        StatRow(
            label: "Thermal state",
            value: store.sensors.map { Self.thermalStateName($0.thermalState) }
        )
        ForEach(Self.grouped(store.sensors?.readings ?? []), id: \.title) { group in
            Text(group.title)
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            ForEach(group.readings, id: \.name) { reading in
                StatRow(label: Self.displayName(for: reading.name), value: Self.formattedValue(reading))
            }
        }
    }
}
