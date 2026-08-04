# Battery Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Battery page in the Hardware section showing live power draw, charge, health and cycle count — present only on machines that have a battery.

**Architecture:** Live electrical values come from `AppleSmartBattery` in the IORegistry on the slow cadence; health values come from `system_profiler -json SPPowerDataType` once at launch via `HardwareProfile`, mirroring how memory already works. `SidebarSection.groups` becomes a function of the hardware profile so the page is absent rather than empty on a desktop Mac.

**Tech Stack:** Swift 6, strict concurrency, macOS 26.0 floor, SwiftUI, swift-testing. No third-party dependencies. IOKit and `IOPSGetBatteryWarningLevel` — all public API.

**Spec:** `docs/superpowers/specs/2026-08-04-battery-page-design.md`

## Global Constraints

- **Never fabricate a number.** An unmeasurable value is `nil`, rendering as "Unavailable" or an em dash — never `0`, never blank, never a guess. A sampler that cannot read **throws**; it does not return empty or zeroed results. When you find yourself writing `?? 0`, stop.
- **Never trust a check you have not seen fail.** Every task has an explicit "watch it go red" step. **Eight** tests written from plans on this project have turned out to assert nothing.
- **Float equality is banned.** Compare with a tolerance. This project has been bitten four separate times.
- **Maximum Capacity is read, never computed.** Apple reports 95%; the two obvious formulas give 90.4% and 92.9%. Deriving it would print a figure that disagrees with Settings.
- **Do not use `IOPSGetPowerSourceDescription`'s `BatteryHealth` key.** Measured on this machine it reports "Check Battery" while `system_profiler` reports healthy. It is wrong and must not be substituted because it is easier to read.
- `swift test --filter` matches **type identifiers**, not `@Suite` display names. A run reporting "Test run with 0 tests … passed" is a failed run — check the count on every run.
- Warning checks need a clean build: `rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`.
- **Charts carry a time axis.** Every `ChartSeries` built from store history must pass `timestamps:`.
- Swift 6 strict concurrency, macOS 26.0 floor.
- Branch from `sensors-spike`. Baseline is **496 tests, 0 warnings**.
- All swift commands run from `/Users/george/Developer/Vitals/VitalsCore`.
- House style: doc comments explain *why*, not what.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/SystemMetrics/Battery/BatterySample.swift` | **New.** Model + pure conversions | 1 |
| `Sources/SystemMetrics/Battery/BatterySampler.swift` | **New.** IORegistry + warning level read | 1 |
| `Sources/SystemMetrics/Battery/BatteryHealth.swift` | **New.** `system_profiler` JSON parsing | 2 |
| `Sources/SystemMetrics/HardwareProfile.swift` | Carry `batteryHealth` | 2 |
| `Sources/MetricsEngine/SeriesKey.swift` | Add `.battery` | 3 |
| `Sources/MetricsEngine/StandardSamplers.swift` | Register the sampler | 3 |
| `Sources/VitalsUI/MetricsStore.swift` | `battery` + `batteryHistory` | 3 |
| `Sources/VitalsUI/Shell/SidebarSection.swift` | `groups` takes the profile | 4 |
| `Sources/VitalsUI/Shell/AppShell.swift` | Pass the profile; route `.battery` | 4, 6 |
| `Sources/VitalsUI/Design/Tokens.swift` | `Palette.battery` | 5 |
| `Sources/VitalsUI/Components/BatteryLevelBar.swift` | **New.** Glyph, bar, colour states | 5 |
| `Sources/VitalsUI/Pages/BatteryPage.swift` | **New.** The page | 6 |

---

## Task 1: Battery model and IORegistry sampler

**Files:**
- Create: `Sources/SystemMetrics/Battery/BatterySample.swift`
- Create: `Sources/SystemMetrics/Battery/BatterySampler.swift`
- Test: `Tests/SystemMetricsTests/BatterySampleTests.swift` (new)

**Interfaces:**
- Produces: `BatterySample`, `BatteryWarningLevel`, `BatterySampler.read() -> BatterySample?`, and the pure conversions `BatterySample.milliamps(fromRegistryValue:)`, `BatterySample.minutesRemaining(fromRegistryValue:)`, `BatterySample.watts(millivolts:milliamps:)`. Tasks 3 and 6 consume `BatterySample`.

**The trap this task exists to avoid.** `AppleSmartBattery`'s `Amperage` is signed but arrives unsigned. Measured on this machine: **charging `4090`**, **discharging `18446744073709550565`** — which is −1051 in `UInt64` wraparound. The bug therefore appears **only while discharging**, so an implementation that reads it naively looks perfect on a plugged-in development machine.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SystemMetricsTests/BatterySampleTests.swift`:

```swift
import Foundation
import Testing
@testable import SystemMetrics

@Suite("Battery sample")
struct BatterySampleTests {

    /// Both directions measured from a real Mac14,9: 4090 while charging,
    /// 18446744073709550565 while discharging. The second is -1051 in UInt64
    /// wraparound, and it only ever appears on battery power — which is why a
    /// naive read looks correct on a plugged-in machine.
    @Test("amperage is reinterpreted from unsigned, in both directions")
    func amperageReinterpretsSign() {
        #expect(BatterySample.milliamps(fromRegistryValue: 4090) == 4090)
        #expect(BatterySample.milliamps(fromRegistryValue: 18_446_744_073_709_550_565) == -1051)
    }

    /// 65535 is the gas gauge's "I don't know yet" sentinel. Rendering it
    /// would claim 45 days of runtime.
    @Test("an unsettled time estimate is nil, never 65535")
    func unsettledTimeEstimateIsNil() {
        #expect(BatterySample.minutesRemaining(fromRegistryValue: 65535) == nil)
        #expect(BatterySample.minutesRemaining(fromRegistryValue: 82) == 82)
        // Zero is a real reading when a battery is empty or full, not a sentinel.
        #expect(BatterySample.minutesRemaining(fromRegistryValue: 0) == 0)
    }

    /// Magnitude, never signed: the chart plots how much power is moving and
    /// the stats say which way. Measured discharging: 11.081 V x 1.051 A.
    @Test("power is the magnitude of volts times amps")
    func powerIsMagnitude() {
        #expect(abs(BatterySample.watts(millivolts: 11081, milliamps: -1051) - 11.646) < 0.01)
        #expect(abs(BatterySample.watts(millivolts: 11081, milliamps: 4090) - 45.32) < 0.01)
        // Charging and discharging at the same rate must plot identically.
        #expect(abs(BatterySample.watts(millivolts: 11081, milliamps: -4090)
                    - BatterySample.watts(millivolts: 11081, milliamps: 4090)) < 1e-9)
    }

    /// Registry temperature is in hundredths of a degree: 3014 is 30.14 degC.
    @Test("temperature converts from hundredths of a degree")
    func temperatureConverts() {
        #expect(abs(BatterySample.celsius(fromRegistryValue: 3014) - 30.14) < 1e-9)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd VitalsCore && swift test --filter BatterySampleTests 2>&1 | tail -20
```

Expected: compile errors — none of these types exist yet.

- [ ] **Step 3: Implement the model and conversions**

Create `Sources/SystemMetrics/Battery/BatterySample.swift`:

```swift
import Foundation

public enum BatteryWarningLevel: Sendable, Equatable {
    case none, early, final
}

public struct BatterySample: Sendable, Equatable {
    /// Magnitude of power moving in or out, in watts.
    ///
    /// Never signed. Current flows out when discharging and in when charging;
    /// plotting -11.6 W and +45.3 W on one axis would conflate two different
    /// physical events, and `.absolute` chart bounds are zero-based so a
    /// negative would clamp to zero and vanish entirely.
    public let watts: Double
    public let chargePercent: Int
    public let isCharging: Bool
    public let isExternalPowerConnected: Bool
    /// `nil` when the gas gauge has not settled — see `minutesRemaining(from:)`.
    public let minutesRemaining: Int?
    public let volts: Double
    public let celsius: Double
    public let warningLevel: BatteryWarningLevel
    public let isLowPowerMode: Bool

    public init(
        watts: Double, chargePercent: Int, isCharging: Bool,
        isExternalPowerConnected: Bool, minutesRemaining: Int?,
        volts: Double, celsius: Double,
        warningLevel: BatteryWarningLevel, isLowPowerMode: Bool
    ) {
        self.watts = watts
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isExternalPowerConnected = isExternalPowerConnected
        self.minutesRemaining = minutesRemaining
        self.volts = volts
        self.celsius = celsius
        self.warningLevel = warningLevel
        self.isLowPowerMode = isLowPowerMode
    }

    /// Reinterprets `AppleSmartBattery`'s `Amperage`, which is a signed value
    /// delivered unsigned.
    ///
    /// Measured on a Mac14,9: `4090` while charging, `18446744073709550565`
    /// while discharging — the latter being -1051 in `UInt64` wraparound. The
    /// defect therefore only manifests on battery power, so an implementation
    /// that skips this looks entirely correct on a plugged-in machine.
    public static func milliamps(fromRegistryValue raw: UInt64) -> Int64 {
        Int64(bitPattern: raw)
    }

    /// The gas gauge reports `65535` for "not yet known". Passing that through
    /// would claim about 45 days of runtime.
    ///
    /// Zero is deliberately NOT treated as a sentinel: an empty or fully
    /// charged battery genuinely has zero minutes left in its current
    /// direction.
    public static func minutesRemaining(fromRegistryValue raw: Int) -> Int? {
        raw == 65535 ? nil : raw
    }

    /// Power as a magnitude. Millivolts and milliamps in, watts out.
    public static func watts(millivolts: Int, milliamps: Int64) -> Double {
        abs(Double(millivolts) / 1000 * Double(milliamps) / 1000)
    }

    /// Registry temperature is in hundredths of a degree Celsius.
    public static func celsius(fromRegistryValue raw: Int) -> Double {
        Double(raw) / 100
    }
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
cd VitalsCore && swift test --filter BatterySampleTests 2>&1 | tail -20
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Prove the sign conversion can fail**

Temporarily change `milliamps` to `Int64(raw)` — the naive read. Confirm
`amperageReinterpretsSign` goes red on the discharging case (it will crash or
report an enormous positive). Restore. Report the output. This is the exact bug
the task exists to prevent.

- [ ] **Step 6: Implement the sampler**

Create `Sources/SystemMetrics/Battery/BatterySampler.swift` with
`public static func read() -> BatterySample?`.

Follow the IOKit pattern already used in
`Sources/SystemMetrics/GPU/GPUSampler.swift` — read it first. It uses
`IOServiceGetMatchingServices` plus `IORegistryEntryCreateCFProperties`; match
on `IOServiceMatching("AppleSmartBattery")`.

Keys to read, all confirmed present on this machine:
`CurrentCapacity` (Int, percent), `Voltage` (Int, mV), `Amperage` (read as
`UInt64` then through `milliamps(fromRegistryValue:)`), `TimeRemaining` (Int),
`IsCharging` (Bool), `ExternalConnected` (Bool), `Temperature` (Int).

Warning level comes from `IOPSGetBatteryWarningLevel()` in `IOKit.ps`, mapped
to `BatteryWarningLevel` via `kIOPSLowBatteryWarningNone` / `…Early` / `…Final`.
Low Power Mode comes from `ProcessInfo.processInfo.isLowPowerModeEnabled`.

Return `nil` — never a zeroed sample — when the service is absent or any
required key is missing. A machine with no battery must produce `nil`, which is
what Task 4 uses to hide the sidebar item.

- [ ] **Step 7: Confirm it reads real hardware**

The pure tests above pass even if the registry walk returns nothing. Add a
temporary test that prints `BatterySampler.read()` and run it with `--filter`.
**Report the actual values you saw.** Expect a charge percent matching
`pmset -g batt`, a plausible wattage, and volts near 11–13. Delete the
temporary test before committing. If it returns `nil` on this machine, the
registry walk is wrong and the pure tests did not catch it.

- [ ] **Step 8: Commit**

```bash
git add VitalsCore/Sources/SystemMetrics/Battery VitalsCore/Tests/SystemMetricsTests/BatterySampleTests.swift
git commit -m "feat: read live battery electrical values from the IORegistry"
```

---

## Task 2: Battery health from `system_profiler`

**Files:**
- Create: `Sources/SystemMetrics/Battery/BatteryHealth.swift`
- Modify: `Sources/SystemMetrics/HardwareProfile.swift`
- Test: `Tests/SystemMetricsTests/BatteryHealthTests.swift` (new)

**Interfaces:**
- Produces: `BatteryHealth(condition:maximumCapacityPercent:cycleCount:)`,
  `BatteryHealthParser.parse(profilerJSON: Data) throws -> BatteryHealth?`, and
  `HardwareProfile.batteryHealth: BatteryHealth?`. Tasks 4 and 6 consume the
  profile property.

**Why this is not computed.** Apple reports Maximum Capacity as **95%**. The two
obvious formulas from raw registry values give 90.4% and 92.9%. Apple's
computation is undocumented, so this is **read**.

- [ ] **Step 1: Write the failing tests**

The exact JSON shape, captured from this machine:

```swift
import Foundation
import Testing
@testable import SystemMetrics

@Suite("Battery health")
struct BatteryHealthTests {

    /// Captured verbatim from `system_profiler -json SPPowerDataType` on a
    /// Mac14,9. Note `sppower_battery_health` is "Good" here while the tool's
    /// own TEXT output — and Settings — say "Normal". That divergence is
    /// accepted, not mapped: only one health state has ever been observed, so
    /// any translation table beyond it would be invented.
    private static let realJSON = Data("""
    {"SPPowerDataType":[{"_name":"spbattery_information",
      "sppower_battery_charge_info":{"sppower_battery_state_of_charge":36},
      "sppower_battery_health_info":{"sppower_battery_cycle_count":128,
        "sppower_battery_health":"Good",
        "sppower_battery_health_maximum_capacity":"95%"}}]}
    """.utf8)

    @Test("health is read from the profiler, never computed")
    func parsesRealOutput() throws {
        let health = try #require(try BatteryHealthParser.parse(profilerJSON: Self.realJSON))
        #expect(health.condition == "Good")
        #expect(health.maximumCapacityPercent == 95)
        #expect(health.cycleCount == 128)
    }

    /// A desktop Mac has no battery block at all. That is `nil`, which is what
    /// hides the sidebar item — not a zeroed BatteryHealth.
    @Test("a machine with no battery yields nil, not an empty reading")
    func noBatteryYieldsNil() throws {
        let none = Data("""
        {"SPPowerDataType":[{"_name":"sppower_ac_info"}]}
        """.utf8)
        #expect(try BatteryHealthParser.parse(profilerJSON: none) == nil)
    }

    /// The capacity arrives as the string "95%", not a number.
    @Test("a capacity that cannot be parsed is nil, never zero")
    func unparseableCapacityIsNil() throws {
        let odd = Data("""
        {"SPPowerDataType":[{"_name":"spbattery_information",
          "sppower_battery_health_info":{"sppower_battery_cycle_count":128,
            "sppower_battery_health":"Good",
            "sppower_battery_health_maximum_capacity":"unknown"}}]}
        """.utf8)
        let health = try #require(try BatteryHealthParser.parse(profilerJSON: odd))
        #expect(health.maximumCapacityPercent == nil)
        #expect(health.cycleCount == 128)
    }
}
```

- [ ] **Step 2: Run and watch fail**

```bash
cd VitalsCore && swift test --filter BatteryHealthTests 2>&1 | tail -20
```

Expected: compile errors.

- [ ] **Step 3: Implement**

Create `Sources/SystemMetrics/Battery/BatteryHealth.swift`:

```swift
import Foundation

/// Apple's own verdict on the battery, read rather than derived.
public struct BatteryHealth: Sendable, Equatable {
    /// Verbatim from `sppower_battery_health`, e.g. "Good".
    ///
    /// Shown as-is. `system_profiler`'s text output and Settings say "Normal"
    /// for this same state, but only one health state has ever been observed
    /// on one machine, so translating would be inventing a mapping.
    public let condition: String
    /// `nil` when the reported string cannot be parsed. Never 0 — a battery
    /// reporting 0% maximum capacity would be a broken measurement, not a
    /// broken battery.
    public let maximumCapacityPercent: Int?
    public let cycleCount: Int?

    public init(condition: String, maximumCapacityPercent: Int?, cycleCount: Int?) {
        self.condition = condition
        self.maximumCapacityPercent = maximumCapacityPercent
        self.cycleCount = cycleCount
    }
}

public enum BatteryHealthParser {
    /// `nil` when the payload contains no battery block at all — a desktop Mac.
    public static func parse(profilerJSON data: Data) throws -> BatteryHealth? {
        struct Payload: Decodable {
            let SPPowerDataType: [Item]
            struct Item: Decodable {
                let _name: String
                let sppower_battery_health_info: HealthInfo?
                struct HealthInfo: Decodable {
                    let sppower_battery_cycle_count: Int?
                    let sppower_battery_health: String?
                    let sppower_battery_health_maximum_capacity: String?
                }
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let info = payload.SPPowerDataType
            .first(where: { $0._name == "spbattery_information" })?
            .sppower_battery_health_info,
            let condition = info.sppower_battery_health
        else { return nil }

        // "95%" — strip the suffix rather than assuming a number.
        let capacity = info.sppower_battery_health_maximum_capacity
            .flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }

        return BatteryHealth(
            condition: condition,
            maximumCapacityPercent: capacity,
            cycleCount: info.sppower_battery_cycle_count
        )
    }
}
```

- [ ] **Step 4: Wire it into `HardwareProfile`**

Add `public let batteryHealth: BatteryHealth?` to `HardwareProfile`, populated in
`detect` from a `powerProfilerOutput()` helper that mirrors the existing
`memoryProfilerOutput()` **exactly** — read that function first; its comments
explain why the pipe is drained before waiting and why a non-zero exit throws.
Arguments are `["-json", "SPPowerDataType"]`.

Unlike memory, a failure here must **not** throw the whole profile: a machine
with no battery is normal, and a `system_profiler` hiccup should cost the
Battery page, not the entire app. Catch and store `nil`.

- [ ] **Step 5: Run and watch pass**

```bash
cd VitalsCore && swift test --filter BatteryHealthTests 2>&1 | tail -20
cd VitalsCore && swift test --filter HardwareProfileTests 2>&1 | tail -10
```

Expected: both PASS.

- [ ] **Step 6: Prove the nil path can fail**

Temporarily make `parse` return a `BatteryHealth(condition: "", …)` instead of
`nil` when there is no battery block. Confirm `noBatteryYieldsNil` goes red.
Restore. Report the output — that `nil` is what Task 4 relies on to hide the
sidebar item.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/SystemMetrics VitalsCore/Tests/SystemMetricsTests/BatteryHealthTests.swift
git commit -m "feat: read battery health from system_profiler rather than deriving it"
```

---

## Task 3: Engine and store wiring

**Files:**
- Modify: `Sources/MetricsEngine/SeriesKey.swift`, `Sources/MetricsEngine/StandardSamplers.swift`
- Modify: `Sources/VitalsUI/MetricsStore.swift`
- Test: `Tests/VitalsUITests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `BatterySampler.read()`, `BatterySample`.
- Produces: `SeriesKey.battery`, `MetricsStore.battery: BatterySample?`,
  `MetricsStore.batteryHistory: [Timestamped<BatterySample>]`. Task 6 consumes both.

- [ ] **Step 1: Write the failing test**

Append inside `struct MetricsStoreTests`, following the `.sensors` test in the
same file as the pattern:

```swift
    @Test("a battery sample lands in the store with history")
    func storesBatterySamples() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let sample = BatterySample(
            watts: 11.6, chargePercent: 22, isCharging: false,
            isExternalPowerConnected: false, minutesRemaining: 79,
            volts: 11.081, celsius: 30.14,
            warningLevel: .none, isLowPowerMode: false
        )
        await engine.register(AnySampler { sample }, for: .battery, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)
        let task = Task { await store.stream(.battery) }
        try await waitUntil { store.battery != nil }
        task.cancel()

        #expect(store.battery?.chargePercent == 22)
        #expect(!store.batteryHistory.isEmpty)
    }
```

- [ ] **Step 2: Run and watch fail**

```bash
cd VitalsCore && swift test --filter MetricsStoreTests 2>&1 | tail -20
```

Expected: compile errors — `SeriesKey.battery` and the store properties do not exist.

- [ ] **Step 3: Add the series key and sampler**

Add `case battery` to `SeriesKey`. In `StandardSamplers.registerAll` add:

```swift
        await engine.register(batterySampler(), for: .battery, cadence: .slow)
```

with the factory beside the others:

```swift
    /// Slow cadence: the gas gauge itself only refreshes every few seconds, so
    /// a 1 Hz sampler would spend power redrawing identical values.
    private static func batterySampler() -> AnySampler {
        AnySampler {
            // Throws rather than publishing a zeroed sample: a machine with no
            // battery must read "Unavailable", not 0 W.
            guard let sample = BatterySampler.read() else { throw SamplerError.unavailable }
            return sample
        }
    }
```

- [ ] **Step 4: Add store properties**

Beside the `sensors` pair in `MetricsStore`:

```swift
    public private(set) var battery: BatterySample?
    public private(set) var batteryHistory: [Timestamped<BatterySample>] = []
```

Add the `.battery` arm to every exhaustive `switch` over `SeriesKey` — the
compiler will name them. Follow the `.sensors` arm exactly. Handle each
explicitly; **do not add a `default:`**, which would silently swallow future
cases.

- [ ] **Step 5: Run and watch pass**

```bash
cd VitalsCore && swift test --filter MetricsStoreTests 2>&1 | tail -20
cd VitalsCore && swift test 2>&1 | tail -8
```

Expected: `MetricsStoreTests` up by one; full suite 504.

`OverheadTests.staysUnderBudget` holds `.sensors` to registration rather than to
producing a sample, because sensor absence is spec-legitimate. **Battery is the
same case** — a desktop Mac has none. Add `.battery` to that same carve-out, with
a comment saying why, or the test will fail on any machine without a battery.

- [ ] **Step 6: Prove the test can fail**

Temporarily delete the `append(...)` call from the `.battery` store arm. Confirm
`storesBatterySamples` goes red on the history expectation. Restore. Report it.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/MetricsEngine VitalsCore/Sources/VitalsUI/MetricsStore.swift VitalsCore/Tests
git commit -m "feat: sample the battery on the slow cadence and keep its history"
```

---

## Task 4: The sidebar becomes conditional

**Files:**
- Modify: `Sources/VitalsUI/Shell/SidebarSection.swift:61-67`
- Modify: `Sources/VitalsUI/Shell/AppShell.swift:14`
- Test: `Tests/VitalsUITests/SidebarSectionTests.swift`

**Interfaces:**
- Consumes: `HardwareProfile.batteryHealth`.
- Produces: `SidebarSection.groups(hasBattery: Bool) -> [Group]` and
  `SidebarSection.battery`.

**Why.** AGENTS.md: inapplicable hardware is *absent* rather than shown empty. A
permanently empty Battery page on a Mac Studio is exactly what that warns
against. `groups` has only three consumers — `AppShell.swift:14` and two tests —
so the blast radius is small.

- [ ] **Step 1: Write the failing tests**

```swift
    /// A Mac Studio has no battery, and the project's rule is that
    /// inapplicable hardware is absent rather than shown empty.
    @Test("Battery appears only on machines that have one")
    func batterySectionIsConditional() {
        let withBattery = SidebarSection.groups(hasBattery: true).flatMap(\.sections)
        let without = SidebarSection.groups(hasBattery: false).flatMap(\.sections)
        #expect(withBattery.contains(.battery))
        #expect(without.contains(.battery) == false)
    }

    /// Everything else must be unaffected by the battery's presence.
    @Test("no other section depends on whether a battery exists")
    func onlyBatteryIsConditional() {
        let withBattery = Set(SidebarSection.groups(hasBattery: true).flatMap(\.sections))
        let without = Set(SidebarSection.groups(hasBattery: false).flatMap(\.sections))
        #expect(withBattery.subtracting(without) == [.battery])
        #expect(without.subtracting(withBattery).isEmpty)
    }
```

The two existing tests in this file call `SidebarSection.groups` as a property
and must be updated to `groups(hasBattery: true)`.

- [ ] **Step 2: Run and watch fail**

```bash
cd VitalsCore && swift test --filter SidebarSectionTests 2>&1 | tail -20
```

Expected: compile errors.

- [ ] **Step 3: Implement**

Add `case battery` to `SidebarSection`, with its title "Battery", an SF Symbol
name (`"battery.100"`), a distinct `disclosureKey`-style identity if the enum
carries one, and `isImplemented` returning `true`.

Change `groups` from a static property to:

```swift
    /// Sections to show, given what this machine actually has.
    ///
    /// Battery is omitted entirely on a machine without one rather than
    /// rendering a permanently empty page — inapplicable hardware is absent,
    /// not shown blank. Taking the fact as a parameter rather than reading the
    /// hardware here keeps this type free of I/O and testable in both states.
    public static func groups(hasBattery: Bool) -> [Group] {
        [
            Group(name: "Monitor", sections: [.overview, .processes]),
            Group(name: "Hardware", sections: [.cpu, .memory, .gpu, .storage, .network, .sensors]
                + (hasBattery ? [.battery] : [])),
            Group(name: "System", sections: [.startup, .services, .users, .history]),
        ]
    }
```

In `AppShell.swift:14`, pass `hasBattery: store.profile?.batteryHealth != nil`.

- [ ] **Step 4: Run and watch pass**

```bash
cd VitalsCore && swift test --filter SidebarSectionTests 2>&1 | tail -20
cd VitalsCore && swift test --filter PageConsistencyTests 2>&1 | tail -10
```

Expected: both PASS. `PageConsistencyTests` pins the set of implemented
sections — add `.battery` to its expected set.

- [ ] **Step 5: Prove it can fail**

Temporarily make `groups` ignore `hasBattery` and always include `.battery`.
Confirm `batterySectionIsConditional` goes red. Restore. Report the output.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Shell VitalsCore/Tests/VitalsUITests
git commit -m "feat: show the Battery section only on machines that have one"
```

---

## Task 5: `Palette.battery` and `BatteryLevelBar`

**Files:**
- Modify: `Sources/VitalsUI/Design/Tokens.swift`
- Create: `Sources/VitalsUI/Components/BatteryLevelBar.swift`
- Test: `Tests/VitalsUITests/BatteryLevelBarTests.swift` (new), `Tests/VitalsUITests/TokensTests.swift`

**Interfaces:**
- Produces: `Vitals.Palette.battery`, `BatteryLevelBar(percent:warningLevel:isLowPowerMode:)`,
  and `BatteryLevelBar.fillColor(warningLevel:isLowPowerMode:) -> Color`.

**Colour states, each from a system signal rather than our judgement:**

| State | Source | Colour |
|---|---|---|
| Normal | — | `Palette.battery` green |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | Yellow |
| `early` | `IOPSGetBatteryWarningLevel()` | Amber |
| `final` | `IOPSGetBatteryWarningLevel()` | `Palette.warning` |

Warning level **wins over** Low Power Mode when both apply: a battery about to
die matters more than a power-saving preference.

The red is the first legitimate use of `Palette.warning`, which was deliberately
kept out of the series ramp so it always means "something is wrong".

- [ ] **Step 1: Write the failing tests**

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Battery level bar")
struct BatteryLevelBarTests {

    /// Every colour here maps to a state macOS itself reports — none is a
    /// threshold this app chose.
    @Test("colour follows the system's own battery state")
    func colourFollowsSystemState() {
        #expect(BatteryLevelBar.fillColor(warningLevel: .none, isLowPowerMode: false)
                == Vitals.Palette.battery)
        #expect(BatteryLevelBar.fillColor(warningLevel: .final, isLowPowerMode: false)
                == Vitals.Palette.warning)
        #expect(BatteryLevelBar.fillColor(warningLevel: .none, isLowPowerMode: true)
                != Vitals.Palette.battery)
    }

    /// A battery about to die matters more than a power-saving preference.
    @Test("a warning outranks low power mode")
    func warningOutranksLowPowerMode() {
        #expect(BatteryLevelBar.fillColor(warningLevel: .final, isLowPowerMode: true)
                == Vitals.Palette.warning)
        #expect(BatteryLevelBar.fillColor(warningLevel: .early, isLowPowerMode: true)
                == BatteryLevelBar.fillColor(warningLevel: .early, isLowPowerMode: false))
    }

    /// Unlike the Sensors thermometer strip, charge is a bounded 0-100%
    /// quantity, so the bar needs no invented endpoints.
    @Test("the fill is proportional and clamped to the real range")
    func fillFractionIsProportional() {
        #expect(abs(BatteryLevelBar.fillFraction(percent: 0) - 0) < 1e-9)
        #expect(abs(BatteryLevelBar.fillFraction(percent: 22) - 0.22) < 1e-9)
        #expect(abs(BatteryLevelBar.fillFraction(percent: 100) - 1) < 1e-9)
        #expect(abs(BatteryLevelBar.fillFraction(percent: 140) - 1) < 1e-9)
    }

    @Test("the bar paints its fill at the right proportion")
    func barPaintsProportionally() throws {
        let rendered = try renderPNG(
            BatteryLevelBar(percent: 50, warningLevel: .none, isLowPowerMode: false)
                .frame(width: 400),
            size: CGSize(width: 400, height: 40), named: "battery-bar-half"
        )
        // Left half filled, right half empty.
        #expect(try regionHasSaturatedColor(in: rendered, region: CGRect(x: 20, y: 0, width: 60, height: 40)))
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(x: 320, y: 0, width: 60, height: 40)))
    }
}
```

Add to `TokensTests`, beside the existing hue checks:

```swift
    @Test("the battery accent is distinct from every other page accent")
    @MainActor
    func batteryAccentIsDistinct() {
        let others = [Vitals.Palette.cpu, Vitals.Palette.memory, Vitals.Palette.gpu,
                      Vitals.Palette.storage, Vitals.Palette.network, Vitals.Palette.sensors]
        let battery = hue(of: Vitals.Palette.battery)
        for other in others {
            let raw = abs(battery - hue(of: other))
            #expect(min(raw, 1 - raw) > 0.1,
                    "battery sits too close in hue to another accent")
        }
    }
```

- [ ] **Step 2: Run and watch fail**

```bash
cd VitalsCore && swift test --filter BatteryLevelBarTests 2>&1 | tail -20
```

Expected: compile errors.

- [ ] **Step 3: Add the accent**

In `Tokens.swift`, beside the other palette entries:

```swift
        /// The Battery page's hue.
        ///
        /// Green at roughly 100 degrees — the largest genuinely free gap in the
        /// ramp, about 50 degrees from `network` (43) and from `storage` (156).
        /// Green-for-battery is also a convention nobody has to learn.
        public static let battery = Color(red: 0.55, green: 0.80, blue: 0.35)
```

If `batteryAccentIsDistinct` fails, adjust the value until it passes — do not
weaken the test.

- [ ] **Step 4: Implement the bar**

Create `Sources/VitalsUI/Components/BatteryLevelBar.swift`. Read
`Sources/VitalsUI/Components/ThermometerStrip.swift` first — it is the closest
analogue and establishes the house patterns for a fixed-height track with a
label. Note especially that its track has an explicit height: a
`GeometryReader`-sized track grows to fill the page's `secondary` slot, which
was a real defect there.

The view is a battery glyph, the percentage, and a horizontal track whose fill
is proportional and coloured by `fillColor`. Do **not** add raw `.glassEffect`
calls — `ImageRenderer` renders them as nothing offscreen; use `glassSurface()`.

```swift
    /// Colour by system state. Warning level outranks Low Power Mode: a
    /// battery about to die matters more than a power-saving preference.
    static func fillColor(warningLevel: BatteryWarningLevel, isLowPowerMode: Bool) -> Color {
        switch warningLevel {
        case .final: return Vitals.Palette.warning
        case .early: return Self.earlyWarningColor
        case .none: return isLowPowerMode ? Self.lowPowerColor : Vitals.Palette.battery
        }
    }

    /// Charge is a bounded 0-100% quantity, so unlike `ThermometerStrip` this
    /// needs no invented endpoints. Clamped because a gas gauge can briefly
    /// report over 100 while calibrating.
    static func fillFraction(percent: Int) -> Double {
        min(max(Double(percent) / 100, 0), 1)
    }
```

- [ ] **Step 5: Run and watch pass**

```bash
cd VitalsCore && swift test --filter BatteryLevelBarTests 2>&1 | tail -20
cd VitalsCore && swift test --filter TokensTests 2>&1 | tail -10
```

Expected: both PASS.

- [ ] **Step 6: Prove the precedence rule can fail**

Temporarily reorder `fillColor` so Low Power Mode is checked before the warning
level. Confirm `warningOutranksLowPowerMode` goes red. Restore. Report the output.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests
git commit -m "feat: add a battery level bar coloured by system state"
```

---

## Task 6: The Battery page

**Files:**
- Create: `Sources/VitalsUI/Pages/BatteryPage.swift`
- Modify: `Sources/VitalsUI/Shell/AppShell.swift`
- Test: `Tests/VitalsUITests/BatteryPageTests.swift` (new)

**Interfaces:**
- Consumes: `MetricsStore.battery` / `.batteryHistory`, `HardwareProfile.batteryHealth`,
  `HardwarePage(..., stacked:, ...)`, `BatteryLevelBar`, `Vitals.Palette.battery`.
- Produces: `BatteryPage(store:)`, `BatteryPage.disclosureKey`,
  `BatteryPage.conditionIsHealthy(_:)`.

**Page content:**

| Slot | Content |
|---|---|
| Title | "Battery", `vendorName: nil` |
| Primary | `watts` formatted, e.g. `11.6 W`; `nil` → em dash |
| Chart | One series, watts, `stacked: false`, with `timestamps:` |
| Secondary | `BatteryLevelBar` |
| Stats | Charge and state · Time remaining · Maximum capacity · Cycle count |
| Specifications | Condition with dot, volts, temperature, adapter state, plus health |

**Do not display the battery's serial number**, although `AppleSmartBattery`
exposes it and System Information shows it. It is a uniquely identifying string
with no monitoring value — it never changes and says nothing about how the
battery is doing — and it would appear in every screenshot of this page.

**Do not attempt Apple's 24-hour or 10-day energy history.** It needs samples
persisted across launches; Vitals holds 600 in memory and only samples while a
page is open. A version built from what is available would silently cover
"since you opened this window" while looking like Apple's graph.

**The status dot fails safe.** Green only for condition strings known to mean
healthy — `Good` and `Normal`, both observed — and `Palette.warning` for
anything else, *including strings never seen before*. An unrecognised verdict
should draw attention rather than be silently treated as fine.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Battery page")
struct BatteryPageTests {

    /// Fails safe: an unrecognised verdict draws attention rather than being
    /// silently treated as fine. "Good" comes from the JSON output and
    /// "Normal" from the text output — both have been observed for a healthy
    /// battery, and Vitals reads the JSON.
    @Test("only known-healthy conditions read as healthy")
    func conditionFailsSafe() {
        #expect(BatteryPage.conditionIsHealthy("Good"))
        #expect(BatteryPage.conditionIsHealthy("Normal"))
        #expect(BatteryPage.conditionIsHealthy("Service Recommended") == false)
        #expect(BatteryPage.conditionIsHealthy("Check Battery") == false)
        // Never seen before, so it must NOT read as healthy.
        #expect(BatteryPage.conditionIsHealthy("Excellent") == false)
    }

    @Test("an unmeasurable time estimate renders as an em dash, never a zero")
    func absentTimeRendersAsEmDash() {
        #expect(BatteryPage.displayMinutes(nil) == "—")
        #expect(BatteryPage.displayMinutes(79) == "1:19")
        #expect(BatteryPage.displayMinutes(45) == "0:45")
    }

    @Test("power is formatted to one decimal with a watt suffix")
    func powerFormatting() {
        #expect(BatteryPage.displayWatts(11.646) == "11.6 W")
        #expect(BatteryPage.displayWatts(nil) == "—")
    }
}
```

- [ ] **Step 2: Run and watch fail**

```bash
cd VitalsCore && swift test --filter BatteryPageTests 2>&1 | tail -20
```

Expected: compile errors — `BatteryPage` does not exist.

- [ ] **Step 3: Implement the page**

Create `Sources/VitalsUI/Pages/BatteryPage.swift` with the static helpers above
and a `body` using `HardwarePage` per the table. Read
`Sources/VitalsUI/Pages/SensorsPage.swift` first — it is the closest analogue
(also `vendorName: nil`, also `stacked: false`, also uses a component in the
secondary slot).

`public static let disclosureKey = "BatteryPage.showFullSpecifications"`, matching
the form its siblings use. `PageConsistencyTests` proves keys are distinct —
add it to that test's list.

The chart series **must** pass `timestamps:` from `store.batteryHistory`, or
gap-breaking silently stops working for this page.

Subscribe with `.task { await store.stream(.battery) }`.

- [ ] **Step 4: Route the page**

In `AppShell.swift`, above the `default:` case:

```swift
        case .battery:
            BatteryPage(store: store)
```

- [ ] **Step 5: Run and watch pass**

```bash
cd VitalsCore && swift test --filter BatteryPageTests 2>&1 | tail -20
cd VitalsCore && swift test 2>&1 | tail -8
```

Expected: `BatteryPageTests` 3 tests PASS; full suite 514.

- [ ] **Step 6: Prove the fail-safe can fail**

Temporarily change `conditionIsHealthy` to return `true` for any non-empty
string. Confirm `conditionFailsSafe` goes red on the "Excellent" case. Restore.
Report the output — that case is the whole point of the rule.

- [ ] **Step 7: Verify in the running app**

```bash
cd ~/Developer/Vitals && ./scripts/build-app.sh && open build/Vitals.app
```

Select Battery. **Confirm through the accessibility API which page is selected
before describing any capture** — an agent on this project once reported a
capture of a different page, and a window that had moved produced another.
Re-read the window bounds immediately before each `screencapture`.

Report what you actually saw for: a live wattage that changes between reads; the
level bar at a proportion matching the percentage; the charge stat agreeing with
`pmset -g batt`; maximum capacity agreeing with
`system_profiler SPPowerDataType`; and the condition dot's colour.

- [ ] **Step 8: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests/BatteryPageTests.swift
git commit -m "feat: add the Battery page"
```

---

## Final verification

- [ ] **Whole suite, twice**, both green.
- [ ] **Clean build** prints `0` warnings.
- [ ] **Walk the app**: every existing page still renders, and the sidebar shows Battery on this machine.
- [ ] **Update `AGENTS.md`**: add the `Amperage` unsigned-wraparound trap to Platform notes — it belongs beside `host_page_size` and `P_TRANSLATED`, because it only manifests on battery power. Add Battery to the completed list.
- [ ] **Update the ledger** `.superpowers/sdd/progress.md` with each task, what it found, and anything surprising.
