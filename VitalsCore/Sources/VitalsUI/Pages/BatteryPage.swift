import Foundation
import SwiftUI
import SystemMetrics

public struct BatteryPage: View {
    /// Exposed so `PageConsistencyTests` can verify no two pages share a key —
    /// a shared key would make one page's disclosure expand every other's.
    public static let disclosureKey = "BatteryPage.showFullSpecifications"

    private let store: MetricsStore

    public init(store: MetricsStore) {
        self.store = store
    }

    // MARK: Pure helpers, tested directly

    /// Fails safe: only strings verbatim confirmed to mean a healthy battery
    /// read as healthy. `system_profiler -json`, which Vitals reads, reports
    /// "Good"; its own text output and Settings report "Normal" for the same
    /// state. Both are known-good. Everything else — including a condition
    /// string never observed before — must NOT read as healthy: an
    /// unrecognised verdict should draw the eye, not be waved through by a
    /// green dot that happens to default to "fine".
    public static func conditionIsHealthy(_ condition: String) -> Bool {
        condition == "Good" || condition == "Normal"
    }

    /// h:mm, matching how Apple's own battery UI writes a time estimate.
    /// `nil` — IOPS is still calculating, or the machine is plugged in and
    /// charged so nothing is counting — renders as an em dash, never as
    /// "0:00", which would read as "no time left" rather than "unknown".
    /// `pmset` prints "(no estimate)" for the same condition.
    public static func displayMinutes(_ minutes: Int?) -> String {
        guard let minutes else { return "—" }
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// One decimal place, watt suffix. `nil` renders as an em dash, never
    /// `0 W` — zero would claim the battery is neither charging nor
    /// discharging, which is not the same claim as "not measured".
    public static func displayWatts(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        return String(format: "%.1f W", watts)
    }

    /// Four states, because plugged-in-and-not-charging is two situations.
    ///
    /// "Charging" while current is flowing in; "Charged" once it has stopped
    /// AND the battery actually reached full; "Not charging" when it has
    /// stopped short of full, which is what macOS holds under optimised
    /// battery charging and reports as "AC attached; not charging"; "On
    /// battery" otherwise.
    ///
    /// All three AC states share `isCharging == false` or differ only in
    /// fullness, so collapsing any pair puts a claim on screen the machine
    /// never made — "73% – Charged" was the observed one.
    static func chargeStateDescription(
        isCharging: Bool, isExternalPowerConnected: Bool, isFullyCharged: Bool
    ) -> String {
        guard isExternalPowerConnected else { return "On battery" }
        if isCharging { return "Charging" }
        return isFullyCharged ? "Charged" : "Not charging"
    }

    /// "Charge" stat text — percentage plus the state `chargeStateDescription`
    /// names. Factored out of `stats` purely so the string interpolation
    /// fits on one line; Swift's plain string literals cannot span lines even
    /// inside `\(...)`.
    private static func chargeAndState(_ battery: BatterySample) -> String {
        let state = chargeStateDescription(isCharging: battery.isCharging, isExternalPowerConnected: battery.isExternalPowerConnected, isFullyCharged: battery.isFullyCharged)
        return "\(battery.chargePercent)% – \(state)"
    }

    /// Green only when `conditionIsHealthy` recognises the string; the fail-
    /// safe applies to colour exactly the same way it applies to the word.
    static func conditionColor(_ condition: String) -> Color {
        conditionIsHealthy(condition) ? Vitals.Palette.battery : Vitals.Palette.warning
    }

    /// One series: watts over time. Charted as a magnitude (see
    /// `BatterySample.watts`'s own doc comment) — there is only ever one
    /// direction of flow on the axis, so `stacked` is always `false`.
    public static func series(history: [Timestamped<BatterySample>]) -> [ChartSeries] {
        guard !history.isEmpty else { return [] }
        return [
            ChartSeries(
                name: "Power",
                values: history.map(\.sample.watts),
                timestamps: history.map(\.timestamp),
                unit: .absolute(suffix: "W")
            ),
        ]
    }

    // MARK: View

    public var body: some View {
        HardwarePage(
            title: "Battery",
            // No vendor mark: a battery has no maker's name worth surfacing
            // the way "Apple M2 Pro" or "Macintosh HD" is — see SensorsPage's
            // header, which reasons the same way for the same slot.
            vendorName: nil,
            showsAppleMark: false,
            primaryValue: store.battery.map { Self.displayWatts($0.watts) },
            series: Self.series(history: store.batteryHistory),
            accent: Vitals.Palette.battery,
            stacked: false,
            stats: stats,
            disclosureKey: Self.disclosureKey
        ) {
            if let battery = store.battery {
                BatteryLevelBar(
                    percent: battery.chargePercent,
                    warningLevel: battery.warningLevel,
                    isLowPowerMode: battery.isLowPowerMode
                )
            }
        } specifications: {
            specificationRows
        }
        .task { await store.stream(.battery) }
    }

    private var stats: [HardwareStat] {
        let battery = store.battery
        let health = store.batteryHealth
        return [
            HardwareStat(
                label: "Charge",
                value: battery.map { Self.chargeAndState($0) }
            ),
            HardwareStat(
                label: "Time remaining",
                value: battery.map { Self.displayMinutes($0.minutesRemaining) }
            ),
            // Read from system_profiler, never derived — see BatteryHealth's
            // own doc comment for why the two obvious formulas both disagree
            // with Apple's own figure.
            HardwareStat(
                label: "Maximum capacity",
                value: health?.maximumCapacityPercent.map { "\($0)%" }
            ),
            HardwareStat(
                label: "Cycle count",
                value: health?.cycleCount.map { "\($0)" }
            ),
        ]
    }

    @ViewBuilder
    private var specificationRows: some View {
        conditionRow
        StatRow(label: "Voltage", value: store.battery.map { String(format: "%.2f V", $0.volts) })
        StatRow(label: "Temperature", value: store.battery.map { ChartUnit.temperature.formatted($0.celsius) })
        StatRow(
            label: "Power adapter",
            value: store.battery.map { $0.isExternalPowerConnected ? "Connected" : "Not connected" }
        )
        // Deliberately no serial number row — see this file's sibling doc in
        // the plan: it's a fixed, uniquely identifying string with no
        // monitoring value, and it would appear in every screenshot of this
        // page.
    }

    /// Mirrors `StatRow`'s own layout (label, spacer, value, bottom hairline)
    /// because `StatRow` has no slot for a colour swatch — Apple's own
    /// battery-health panel puts a dot beside the condition, and that dot is
    /// the whole point of `conditionColor`'s fail-safe.
    private var conditionRow: some View {
        HStack {
            Text("Condition")
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let condition = store.batteryHealth?.condition {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.conditionColor(condition))
                        .frame(width: 8, height: 8)
                    Text(condition)
                        .font(Vitals.Typography.label)
                        .foregroundStyle(.primary)
                }
            } else {
                Text(StatRow.displayValue(nil))
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
        }
    }
}
