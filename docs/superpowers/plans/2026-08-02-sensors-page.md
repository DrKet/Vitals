# Sensors Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Sensors page showing real temperatures from `IOHIDEventSystemClient`, with a floating-baseline chart, a fixed-scale thermometer strip, and no fabricated readings.

**Architecture:** A concrete `IOHIDSensorProvider` implements the `SensorProviding` protocol that already exists in `SystemMetrics/Sensors/`. Duplicate sensor names aggregate by max with an instance count, because the spike proved no unique identity exists. Two shared chart changes support it: `HardwarePage` takes an explicit `stacked:` (temperatures must never sum) and `ChartUnit` gains a `.temperature` case carrying a non-zero baseline (a 2 °C signal is invisible on a zero-based axis).

**Tech Stack:** Swift 6, strict concurrency, macOS 26.0 floor, SwiftUI, swift-testing. No third-party dependencies. Private IOKit symbols resolved via `dlsym`.

**Spec:** `docs/superpowers/specs/2026-08-02-sensors-page-design.md`
**Spike (the working reference for every IOKit call):** `docs/superpowers/spikes/2026-08-02-sensors-spike.md` and `scripts/spike-sensors.swift`

## Global Constraints

- **Never fabricate a number.** An unmeasurable value is `nil`, rendering as "Unavailable" or an em dash — never `0`, never blank, never a guess. A sampler that cannot produce a reading **throws**; it does not return an empty or zeroed result. When you find yourself writing `?? 0`, stop.
- **Attributing a real measurement to the wrong hardware is the same class of error as inventing one.** This governs every naming decision here.
- **Never trust a check you have not seen fail.** Every task below has an explicit "watch it go red" step. In the previous milestone five tests stayed green when the exact defect they guarded was reintroduced.
- **Float equality is banned.** Compare with a tolerance. This project has been bitten four separate times, and this plan does floating-point range maths.
- `swift test --filter` matches **type identifiers**, not `@Suite` display names. `--filter ChartGeometryTests` works; `--filter "Chart geometry"` matches zero tests **and still reports success**. Check the test count on every run.
- Warning checks need a clean build: `rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`.
- **Charts carry a time axis.** Every `ChartSeries` built from store history must pass `timestamps:`, or gap-breaking silently stops working for that page.
- **Series order is load-bearing.** The first series is the base band, painted frontmost, and marked by the live dot.
- `Int(Double.infinity)` **traps** in Swift. Any numeric conversion needs a finite check — the previous milestone hit exactly this.
- Branch is `sensors-spike`, already rebased onto `visual-polish`. Baseline is **460 tests, 0 warnings**.
- All swift commands run from `/Users/george/Developer/Vitals/VitalsCore`.
- Render tests need a **GUI login session**.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/SystemMetrics/Sensors/SensorReading.swift` | Add `sensorCount`, add `SensorSample` | 1 |
| `Sources/SystemMetrics/Sensors/IOHIDSensorProvider.swift` | **New.** The real provider + aggregation | 2 |
| `Sources/SystemMetrics/HardwareProfile.swift` | Default to the real provider | 3 |
| `Sources/MetricsEngine/SeriesKey.swift` | Add `.sensors` | 3 |
| `Sources/MetricsEngine/StandardSamplers.swift` | Register the sensors sampler | 3 |
| `Sources/VitalsUI/MetricsStore.swift` | `sensors` + `sensorHistory` | 3 |
| `Sources/VitalsUI/Charts/ChartGeometry.swift` | `.temperature`, `bounds`, `axisMinimum` | 4 |
| `Sources/VitalsUI/Charts/MetricChart.swift` | Lower bound + both axis labels | 5 |
| `Sources/VitalsUI/Pages/HardwarePage.swift` | Explicit `stacked:` | 6 |
| `Sources/VitalsUI/Components/ThermometerStrip.swift` | **New.** Fixed-scale strip | 7 |
| `Sources/VitalsUI/Pages/SensorsPage.swift` | **New.** The page | 8 |
| `Sources/VitalsUI/Design/Tokens.swift` | `Palette.sensors` | 8 |
| `Sources/VitalsUI/Shell/AppShell.swift` | Route `.sensors` | 8 |

---

## Task 1: Extend the sensor model

**Files:**
- Modify: `Sources/SystemMetrics/Sensors/SensorReading.swift`
- Test: `Tests/SystemMetricsTests/SensorReadingTests.swift` (new)

**Interfaces:**
- Produces: `SensorReading(name:kind:value:sensorCount:)` and
  `SensorSample(readings:thermalState:)`. Tasks 2, 3 and 8 consume both.

- [ ] **Step 1: Write the failing test**

Create `Tests/SystemMetricsTests/SensorReadingTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd VitalsCore && swift test --filter SensorReadingTests 2>&1 | tail -20
```

Expected: compile error — `SensorReading` has no `sensorCount`, and
`SensorSample` does not exist.

- [ ] **Step 3: Implement**

In `Sources/SystemMetrics/Sensors/SensorReading.swift`, add `sensorCount` to
`SensorReading` (and to its `init`):

```swift
    /// How many sensors reported this name.
    ///
    /// The spike (docs/superpowers/spikes/2026-08-02-sensors-spike.md) found
    /// no unique identifier for a sensor: `RegistryID` and `UniqueID` are
    /// absent, and `Product`+`LocationID` still collides on 28 of the 64
    /// temperature sensors, because `LocationID` is only a FourCC of the name.
    /// So a reading names a *group*, and this is how many sensors are in it —
    /// a measured fact, and the honest answer to "which sensor is this", which
    /// has no better answer.
    public let sensorCount: Int
```

Then append to the same file:

```swift
/// One tick of sensor data.
///
/// Separate from `SensorReading` because `thermalState` is a property of the
/// machine, not of any one sensor.
public struct SensorSample: Sendable, Equatable {
    public let readings: [SensorReading]

    /// Apple's own thermal severity signal, and the only severity source in
    /// this design. Every alternative would require choosing temperature
    /// thresholds, and the spike could not establish this machine's limits —
    /// so a threshold we picked would assert something about the hardware that
    /// was never measured.
    public let thermalState: ProcessInfo.ThermalState

    public init(readings: [SensorReading], thermalState: ProcessInfo.ThermalState) {
        self.readings = readings
        self.thermalState = thermalState
    }
}
```

`SensorReading.swift` imports `Foundation` already, which supplies
`ProcessInfo.ThermalState`.

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd VitalsCore && swift test --filter SensorReadingTests 2>&1 | tail -20
```

Expected: PASS, 2 tests.

- [ ] **Step 5: Fix the one existing call site**

`Tests/SystemMetricsTests/HardwareProfileTests.swift:39` uses
`UnavailableSensorProvider().readings()`, which still compiles. But
`UnavailableSensorProvider` must keep conforming — build the whole package to
confirm nothing else constructs a `SensorReading`:

```bash
cd VitalsCore && swift build --build-tests 2>&1 | grep -E "error|warning" | head
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/SystemMetrics/Sensors/SensorReading.swift VitalsCore/Tests/SystemMetricsTests/SensorReadingTests.swift
git commit -m "feat: give a sensor reading its instance count and add SensorSample"
```

---

## Task 2: The real IOHID provider

**Files:**
- Create: `Sources/SystemMetrics/Sensors/IOHIDSensorProvider.swift`
- Test: `Tests/SystemMetricsTests/IOHIDSensorProviderTests.swift` (new)

**Interfaces:**
- Consumes: `SensorReading(name:kind:value:sensorCount:)`, `SensorProviding`.
- Produces: `IOHIDSensorProvider()` conforming to `SensorProviding`, plus
  `static func aggregate(_ raw: [(name: String, celsius: Double)]) -> [SensorReading]`
  — `internal`, so tests can reach it via `@testable`.

**Port from `scripts/spike-sensors.swift`.** It is the working reference that
produced the spike's readings; do not rediscover the symbol signatures. The
six symbols are `IOHIDEventSystemClientCreate`,
`IOHIDEventSystemClientSetMatching`, `IOHIDEventSystemClientCopyServices`,
`IOHIDServiceClientCopyProperty`, `IOHIDServiceClientCopyEvent`,
`IOHIDEventGetFloatValue`. Match `{"PrimaryUsagePage": 0xff00}`; read event
type `15` at field `15 << 16`; the name is the `Product` property.

- [ ] **Step 1: Write the failing test**

The device walk needs real hardware, so the *aggregation* carries the coverage
— it is pure and is where the spike's constraint actually lives.

Create `Tests/SystemMetricsTests/IOHIDSensorProviderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd VitalsCore && swift test --filter IOHIDSensorProviderTests 2>&1 | tail -20
```

Expected: compile error — `IOHIDSensorProvider` does not exist.

- [ ] **Step 3: Implement the provider**

Create `Sources/SystemMetrics/Sensors/IOHIDSensorProvider.swift`. Port the
symbol resolution and device walk from `scripts/spike-sensors.swift`. The
aggregation must be exactly:

```swift
    /// Groups raw per-sensor readings by name, keeping the hottest.
    ///
    /// The spike proved sensors carry no unique identity, so a name is the
    /// finest grain that can be honestly labelled. Indexing duplicates as
    /// `#1`/`#2` was rejected: service order is stable within one process, but
    /// nothing establishes that `#1` is the same physical sensor across
    /// launches, so the index would be a distinction this code invented.
    ///
    /// Sorted by name so the order cannot drift between runs.
    static func aggregate(_ raw: [(name: String, celsius: Double)]) -> [SensorReading] {
        var grouped: [String: (hottest: Double, count: Int)] = [:]
        for entry in raw {
            if let existing = grouped[entry.name] {
                grouped[entry.name] = (Swift.max(existing.hottest, entry.celsius), existing.count + 1)
            } else {
                grouped[entry.name] = (entry.celsius, 1)
            }
        }
        return grouped
            .map { SensorReading(name: $0.key, kind: .temperatureCelsius, value: $0.value.hottest, sensorCount: $0.value.count) }
            .sorted { $0.name < $1.name }
    }
```

Requirements on the rest of the file:

- Symbols resolved with `dlsym` on
  `/System/Library/Frameworks/IOKit.framework/IOKit`, **not** linked. If any
  symbol is missing, `availability` is
  `.unavailable(reason:)` naming what was missing, and `readings()` returns
  `[]`. A future OS dropping a symbol must degrade, not crash.
- Discard any value that is not finite. **Do not** discard zero — a legitimate
  zero is a reading, and the spike's own probe was wrong to filter zeros out.
- The type must be `Sendable` to satisfy `SensorProviding`. Cache the resolved
  function pointers in `let` properties resolved once in `init`.

- [ ] **Step 4: Run and watch it pass**

```bash
cd VitalsCore && swift test --filter IOHIDSensorProviderTests 2>&1 | tail -20
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Prove the aggregation test can fail**

Temporarily change `Swift.max(existing.hottest, entry.celsius)` to
`Swift.min(...)`, re-run, and confirm `aggregatesDuplicatesByMax` goes red on
the 38.5 expectation. Restore. Then temporarily change `count + 1` to `count`
and confirm the `sensorCount == 3` expectation goes red. Restore. Report both.

- [ ] **Step 6: Confirm it reads real hardware**

The unit tests above pass even if the device walk returns nothing. Verify the
provider actually works on this machine:

Add a temporary test to `IOHIDSensorProviderTests`:

```swift
    @Test("TEMPORARY probe")
    func temporaryProbe() {
        let provider = IOHIDSensorProvider()
        print("availability:", provider.availability)
        let readings = provider.readings()
        print("count:", readings.count)
        for reading in readings.prefix(5) {
            print("  \(reading.name) \(reading.value) n=\(reading.sensorCount)")
        }
        #expect(!readings.isEmpty)
    }
```

Run `swift test --filter IOHIDSensorProviderTests 2>&1 | grep -A8 "count:"`.
Expect a non-zero count and names matching the spike (`PMU tdie*`,
`gas gauge battery`, `NAND CH0 temp`). **Report the actual count and three
names you saw**, then delete the temporary test before committing. If the count
is zero the device walk is wrong and the pure unit tests above did not catch
it — that is exactly the failure mode this step exists for.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/SystemMetrics/Sensors/IOHIDSensorProvider.swift VitalsCore/Tests/SystemMetricsTests/IOHIDSensorProviderTests.swift
git commit -m "feat: read real temperatures through IOHIDEventSystemClient"
```

---

## Task 3: Engine and store wiring

**Files:**
- Modify: `Sources/SystemMetrics/HardwareProfile.swift:23`
- Modify: `Sources/MetricsEngine/SeriesKey.swift:4-12`
- Modify: `Sources/MetricsEngine/StandardSamplers.swift:11-18`
- Modify: `Sources/VitalsUI/MetricsStore.swift`
- Test: `Tests/VitalsUITests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `IOHIDSensorProvider()`, `SensorSample(readings:thermalState:)`.
- Produces: `SeriesKey.sensors`; `MetricsStore.sensors: SensorSample?` and
  `MetricsStore.sensorHistory: [Timestamped<SensorSample>]`. Task 8 consumes both.

- [ ] **Step 1: Write the failing test**

Append to `Tests/VitalsUITests/MetricsStoreTests.swift`, following the
existing tests' construction pattern in that file:

```swift
    @Test("a sensor sample lands in the store with history")
    func storesSensorSamples() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let sample = SensorSample(
            readings: [SensorReading(name: "PMU tdie0", kind: .temperatureCelsius, value: 36.5, sensorCount: 2)],
            thermalState: .nominal
        )
        await engine.register(AnySampler { sample }, for: .sensors, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)
        let task = Task { await store.stream(.sensors) }
        try await waitUntil { store.sensors != nil }
        task.cancel()

        #expect(store.sensors?.readings.first?.name == "PMU tdie0")
        #expect(!store.sensorHistory.isEmpty)
    }
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd VitalsCore && swift test --filter MetricsStoreTests 2>&1 | tail -20
```

Expected: compile error — `SeriesKey.sensors`, `store.sensors` and
`store.sensorHistory` do not exist.

- [ ] **Step 3: Add the series key**

In `Sources/MetricsEngine/SeriesKey.swift`, add `case sensors` to the enum.

- [ ] **Step 4: Register the sampler**

In `Sources/MetricsEngine/StandardSamplers.swift`, add to `registerAll`:

```swift
        await engine.register(sensorSampler(), for: .sensors, cadence: .slow)
```

and add the factory alongside the others:

```swift
    /// Slow cadence deliberately: the spike measured a 2.13 °C move across a
    /// full CPU load ramp, so a fast cadence would spend power redrawing
    /// identical values.
    private static func sensorSampler() -> AnySampler {
        let provider = IOHIDSensorProvider()
        return AnySampler {
            guard provider.availability.isAvailable else { throw SamplerError.unavailable }
            let readings = provider.readings()
            // Throws rather than publishing an empty sample: an empty array
            // would render as a page with no rows rather than "Unavailable".
            guard !readings.isEmpty else { throw SamplerError.unavailable }
            return SensorSample(
                readings: readings,
                thermalState: ProcessInfo.processInfo.thermalState
            )
        }
    }
```

- [ ] **Step 5: Default `HardwareProfile` to the real provider**

In `Sources/SystemMetrics/HardwareProfile.swift:23`, change the default
parameter from `UnavailableSensorProvider()` to `IOHIDSensorProvider()`.
Leave `UnavailableSensorProvider` in the codebase — it is what makes the
unavailable path testable without hardware, and `HardwareProfileTests` uses it.

- [ ] **Step 6: Add store properties**

In `Sources/VitalsUI/MetricsStore.swift`, beside the existing `gpu`/`gpuHistory`
pair (around line 41):

```swift
    public private(set) var sensors: SensorSample?
    public private(set) var sensorHistory: [Timestamped<SensorSample>] = []
```

In the `switch key` in `apply` (around line 120), beside the `.gpu` case:

```swift
        case .sensors:
            guard let sample = value.value as? SensorSample else { return }
            sensors = sample
            append(Timestamped(timestamp: value.timestamp, sample: sample), to: &sensorHistory)
            armStalenessWatch(for: key)
```

And in the reset `switch` (around line 235): `case .sensors: sensors = nil`.

Check whether `SeriesKey` appears in any other exhaustive `switch` — the
compiler will tell you. Search with:

```bash
cd VitalsCore && grep -rn "case .diskIO" Sources | grep -v StandardSamplers
```

Every site that lists `.diskIO` is a switch that now also needs `.sensors`.

- [ ] **Step 7: Run and watch it pass**

```bash
cd VitalsCore && swift test --filter MetricsStoreTests 2>&1 | tail -20
```

Expected: PASS, 23 tests (22 baseline + 1).

- [ ] **Step 8: Run the whole suite**

```bash
cd VitalsCore && swift test 2>&1 | tail -8
```

Expected: 468 tests, 0 failures. `PageConsistencyTests` and any test iterating
`SeriesKey.allCases` may need updating for the new case — if one fails, it is
telling you a real place `.sensors` must be handled.

- [ ] **Step 9: Commit**

```bash
git add VitalsCore/Sources/MetricsEngine VitalsCore/Sources/SystemMetrics/HardwareProfile.swift VitalsCore/Sources/VitalsUI/MetricsStore.swift VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift
git commit -m "feat: sample sensors on the slow cadence and keep their history"
```

---

## Task 4: `ChartUnit.temperature` and the bounds pair

**Files:**
- Modify: `Sources/VitalsUI/Charts/ChartGeometry.swift`
- Test: `Tests/VitalsUITests/ChartGeometryTests.swift`

**Interfaces:**
- Produces, on `ChartGeometry`:
  - `ChartUnit.temperature` (new case)
  - `static func bounds(for stacked: [[Double]], unit: ChartUnit) -> (lower: Double, upper: Double)`
  - `static func axisMinimum(for stacked: [[Double]], unit: ChartUnit) -> NiceBound?`
- `upperBound(for:unit:)`, `axisMaximum(for:unit:)` and `axisLabel(_:unit:)`
  keep their exact current signatures. Task 5 consumes all of these.

- [ ] **Step 1: Write the failing tests**

Append inside `struct ChartGeometryTests`:

```swift
    /// The rule: round outward to multiples of 5, and push off the axis when
    /// the data lands exactly on one. A baseline tracking raw min/max would
    /// move every tick and reshape the chart on steady readings — the defect
    /// the previous milestone removed from absolute charts.
    @Test("temperature bounds round outward to multiples of five")
    func temperatureBoundsRoundOutward() {
        // The spike's real capture: die, battery and storage together.
        let bands = [[36.69, 38.82], [28.50, 28.80], [29.00, 32.00]]
        let bounds = ChartGeometry.bounds(for: bands, unit: .temperature)
        #expect(abs(bounds.lower - 25) < 1e-9)
        #expect(abs(bounds.upper - 40) < 1e-9)
    }

    /// Data sitting exactly on a multiple of 5 must not be drawn on the axis
    /// itself, and the span must never collapse to zero.
    @Test("temperature bounds push off the axis when data lands on a multiple")
    func temperatureBoundsAvoidTheAxis() {
        let bounds = ChartGeometry.bounds(for: [[30.0, 30.0]], unit: .temperature)
        #expect(abs(bounds.lower - 25) < 1e-9)
        #expect(abs(bounds.upper - 35) < 1e-9)
        #expect(bounds.upper - bounds.lower >= 5)
    }

    @Test("a temperature chart labels both ends")
    func temperatureLabelsBothEnds() {
        let bands = [[36.69, 38.82]]
        let low = ChartGeometry.axisMinimum(for: bands, unit: .temperature)
        let high = ChartGeometry.axisMaximum(for: bands, unit: .temperature)
        #expect(ChartGeometry.axisLabel(low!, unit: .temperature) == "35 °C")
        #expect(ChartGeometry.axisLabel(high!, unit: .temperature) == "40 °C")
    }

    /// Zero-based units have nothing worth labelling at the bottom — a "0"
    /// restates what the baseline already says.
    @Test("zero-based units have no minimum label")
    func zeroBasedUnitsHaveNoMinimumLabel() {
        #expect(ChartGeometry.axisMinimum(for: [[0.4]], unit: .fraction) == nil)
        #expect(ChartGeometry.axisMinimum(for: [[41.25]], unit: .absolute(suffix: "MB/s")) == nil)
    }

    /// The load-bearing regression guard: adding a unit case must not move any
    /// existing chart by a single point.
    @Test("existing units are byte-identical through the new bounds function")
    func existingUnitsAreUnchanged() {
        let bands = [[0.2, 0.4, 0.37]]
        #expect(abs(ChartGeometry.bounds(for: bands, unit: .fraction).lower) < 1e-9)
        #expect(abs(ChartGeometry.bounds(for: bands, unit: .fraction).upper - 1.0) < 1e-9)

        let absolute = [[0.01, 41.25]]
        let unit = ChartUnit.absolute(suffix: "MB/s")
        #expect(abs(ChartGeometry.bounds(for: absolute, unit: unit).lower) < 1e-9)
        #expect(abs(ChartGeometry.bounds(for: absolute, unit: unit).upper
                    - ChartGeometry.upperBound(for: absolute, unit: unit)) < 1e-9)
    }

    @Test("a temperature formats to one decimal with a degree suffix")
    func temperatureFormatting() {
        #expect(ChartUnit.temperature.formatted(38.82) == "38.8 °C")
    }
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd VitalsCore && swift test --filter ChartGeometryTests 2>&1 | tail -20
```

Expected: compile errors — `.temperature`, `bounds`, `axisMinimum` do not exist.

- [ ] **Step 3: Add the unit case**

In `ChartUnit`, add `case temperature`, and add to `formatted(_:)`:

```swift
        case .temperature:
            // One decimal, not the two `.absolute` uses: readings arrive
            // quantised to ~0.09 °C on Apple Silicon and storage to whole
            // degrees, so "38.82 °C" claims a precision the sensor does not
            // have. And not zero decimals, which would hide the ~2 °C signal
            // this page exists to show.
            return String(format: "%.1f °C", value)
```

- [ ] **Step 4: Add `bounds` and route the existing functions through it**

```swift
    /// Both ends of a chart's scale.
    ///
    /// The single source of truth: `upperBound` delegates here, so the value
    /// the renderer plots against and the value a label prints cannot drift.
    public static func bounds(for stacked: [[Double]], unit: ChartUnit) -> (lower: Double, upper: Double) {
        switch unit {
        case .fraction, .absolute:
            return (0, upperBoundIgnoringLower(for: stacked, unit: unit))
        case .temperature:
            let values = stacked.flatMap { $0 }
            // No data draws nothing, so this range only has to be
            // non-degenerate — it is a scale, not a reading.
            guard let low = values.min(), let high = values.max() else { return (0, 5) }

            var lower = (low / 5).rounded(.down) * 5
            var upper = (high / 5).rounded(.up) * 5
            // Tolerance, never `==`: these are derived quantities and this
            // project has been bitten four times by exact float comparison.
            if abs(lower - low) < 1e-9 { lower -= 5 }
            if abs(upper - high) < 1e-9 { upper += 5 }
            return (lower, upper)
        }
    }
```

Rename the existing body of `upperBound(for:unit:)` to a private
`upperBoundIgnoringLower(for:unit:)` and make `upperBound` delegate:

```swift
    public static func upperBound(for stacked: [[Double]], unit: ChartUnit) -> Double {
        bounds(for: stacked, unit: unit).upper
    }
```

- [ ] **Step 5: Add `axisMinimum` and extend the two label functions**

```swift
    /// The lower end of a chart's scale, or `nil` when that end is a known
    /// zero and therefore not worth the ink.
    public static func axisMinimum(for stacked: [[Double]], unit: ChartUnit) -> NiceBound? {
        guard case .temperature = unit else { return nil }
        return NiceBound(value: bounds(for: stacked, unit: unit).lower, decimals: 0)
    }
```

In `axisMaximum(for:unit:)`, change `guard case .absolute = unit else { return nil }`
so `.temperature` also returns a bound — for `.temperature` it is
`NiceBound(value: bounds(...).upper, decimals: 0)`. Decimals are `0` because
both ends are multiples of 5.

In `axisLabel(_:unit:)`, add a `.temperature` case returning
`String(format: "%.\(bound.decimals)f °C", bound.value)`.

- [ ] **Step 6: Update `points` to take a lower bound**

```swift
    public static func points(
        _ values: [Double],
        in rect: CGRect,
        lowerBound: Double = 0,
        upperBound: Double
    ) -> [CGPoint] {
```

with the mapping becoming
`let clamped = min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)`
and the existing `guard upperBound > 0` becoming `guard upperBound > lowerBound`.
The default keeps every existing caller unchanged.

- [ ] **Step 7: Run and watch them pass**

```bash
cd VitalsCore && swift test --filter ChartGeometryTests 2>&1 | tail -20
```

Expected: PASS. Test count up by 6.

- [ ] **Step 8: Prove the regression guard can fail**

Temporarily change the `.fraction, .absolute` branch of `bounds` to return
`(1, ...)` instead of `(0, ...)`. Confirm `existingUnitsAreUnchanged` goes red
**and** that several `StoragePageTests`/`NetworkPageTests` render tests go red
too. Restore. Report the output — if the existing-units test stays green while
page tests fail, the guard is not doing its job.

- [ ] **Step 9: Whole suite and commit**

```bash
cd VitalsCore && swift test 2>&1 | tail -8
```

Expected: 474 tests, 0 failures.

```bash
git add VitalsCore/Sources/VitalsUI/Charts/ChartGeometry.swift VitalsCore/Tests/VitalsUITests/ChartGeometryTests.swift
git commit -m "feat: give charts a lower bound via a temperature unit"
```

---

## Task 5: `MetricChart` draws a floating baseline and both labels

**Files:**
- Modify: `Sources/VitalsUI/Charts/MetricChart.swift`
- Test: `Tests/VitalsUITests/MetricChartTests.swift`

**Interfaces:**
- Consumes: `ChartGeometry.bounds(for:unit:)`, `axisMinimum(for:unit:)`,
  `axisMaximum(for:unit:)`, `axisLabel(_:unit:)`,
  `points(_:in:lowerBound:upperBound:)`.

- [ ] **Step 1: Write the failing test**

Append inside `MetricChartTests`' suite:

```swift
    /// A zero-based chart would compress the spike's real 2.13 °C swing into
    /// 4% of the canvas height. With a floating baseline it must occupy a
    /// visible fraction of it — this asserts the band is drawn well away from
    /// the bottom edge, which can only happen if the lower bound is non-zero.
    @Test("a temperature chart plots against a floating baseline")
    func temperatureChartFloatsItsBaseline() throws {
        let series = [ChartSeries(
            name: "Die",
            values: [36.69, 37.5, 38.82],
            unit: .temperature
        )]
        let chart = MetricChart(series: series, style: .area(stacked: false), colors: [Vitals.Palette.cpu], showsAxisMaximum: true)
        let rendered = try renderPNG(chart, size: CGSize(width: 400, height: 200), named: "chart-temperature-floating")

        // The discriminator is where the STROKE sits, not where the fill
        // reaches: `drawAreas` fills from the curve down to the baseline in
        // both configurations, so "is there colour in the lower half" is true
        // either way and would assert nothing.
        //
        // Bounds 35–40 put the samples at 34%–76% of the height, i.e. the
        // curve runs through the middle. Zero-based bounds (0–40) would put
        // them at 92%–97%, i.e. hard against the top.
        let topStrip = CGRect(x: 0, y: 0, width: 400, height: 24)
        let middleBand = CGRect(x: 0, y: 60, width: 400, height: 80)
        #expect(try !regionHasSaturatedColor(in: rendered, region: topStrip))
        #expect(try regionHasSaturatedColor(in: rendered, region: middleBand))
    }

    @Test("a temperature chart labels both ends of its scale")
    func temperatureChartLabelsBothEnds() throws {
        let series = [ChartSeries(name: "Die", values: [36.69, 38.82], unit: .temperature)]
        let chart = MetricChart(series: series, style: .area(stacked: false), colors: [Vitals.Palette.cpu], showsAxisMaximum: true)
        let rendered = try renderPNG(chart, size: CGSize(width: 400, height: 200), named: "chart-temperature-labels")

        #expect(try regionHasContent(in: rendered, region: CGRect(x: 2, y: 0, width: 90, height: 18)))
        #expect(try regionHasContent(in: rendered, region: CGRect(x: 2, y: 182, width: 90, height: 18)))
    }
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd VitalsCore && swift test --filter MetricChartTests 2>&1 | tail -20
```

Expected: FAIL. The chart currently plots from zero, so nothing paints in the
lower half, and no bottom label is drawn.

- [ ] **Step 3: Implement**

In the `Canvas` closure, replace the single `bound` with the pair, and thread
the lower bound through `drawAreas` into `ChartGeometry.points`:

```swift
                let chartUnit = series.first?.unit ?? .fraction
                let scale = ChartGeometry.bounds(for: bands, unit: chartUnit)
```

`drawAreas` gains a `lowerBound:` parameter and passes it to
`ChartGeometry.points(_:in:lowerBound:upperBound:)`. `drawHistogram` keeps its
zero baseline: bars are anchored to `rect.maxY` by construction, and a
floating-baseline bar chart would misrepresent magnitude.

Extend `drawAxisMaximum` (or add a sibling) so it draws the minimum at the plot
rect's **bottom**-leading corner when `axisMinimum` returns non-nil, mirroring
where the maximum is drawn.

- [ ] **Step 4: Run and watch them pass**

```bash
cd VitalsCore && swift test --filter MetricChartTests 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Prove the floating-baseline test can fail**

Temporarily hardcode `lowerBound: 0` in the `drawAreas` call. Confirm
`temperatureChartFloatsItsBaseline` goes red. Restore. Report the output.

- [ ] **Step 6: Whole suite, clean build, commit**

```bash
cd VitalsCore && swift test 2>&1 | tail -8
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

Expected: 476 tests, 0 failures; `0` warnings.

```bash
git add VitalsCore/Sources/VitalsUI/Charts/MetricChart.swift VitalsCore/Tests/VitalsUITests/MetricChartTests.swift
git commit -m "feat: plot temperature charts against a floating, labelled baseline"
```

---

## Task 6: `HardwarePage` takes an explicit `stacked:`

**Files:**
- Modify: `Sources/VitalsUI/Pages/HardwarePage.swift`
- Modify: `Sources/VitalsUI/Pages/{CPUPage,MemoryPage,GPUPage,StoragePage,NetworkPage}.swift`
- Test: `Tests/VitalsUITests/HardwarePageTests.swift`

**Interfaces:**
- Produces: `HardwarePage.init(..., stacked: Bool, ...)` with **no default**.
  Task 8 consumes it.

**Why no default.** Inferring `stacked: series.count > 1` is right for all five
existing pages and wrong for the first page whose series are not additive. A
stacked die at 38 °C and battery at 28 °C would draw a band at 66 °C — a value
no sensor reported. A default would leave that trap armed for the next such
page, which is exactly how the axis label reached the Overview tiles last
milestone.

- [ ] **Step 1: Write the failing test**

```swift
    /// Builds the same two-series temperature page at either stacking setting.
    private func page(stacked: Bool) -> some View {
        HardwarePage(
            title: "Sensors", vendorName: nil, showsAppleMark: false,
            primaryValue: "38.8 °C",
            series: [
                ChartSeries(name: "Die", values: [38.0, 38.0, 38.0], unit: .temperature),
                ChartSeries(name: "Battery", values: [28.0, 28.0, 28.0], unit: .temperature),
            ],
            accent: Vitals.Palette.cpu,
            stacked: stacked,
            stats: [],
            disclosureKey: "test.sensors"
        ) { EmptyView() } specifications: { EmptyView() }
    }

    /// Temperatures must never sum: a die at 38 °C and a battery at 28 °C
    /// would draw a band at 66 °C, a value no sensor reported.
    @Test("stacking actually changes what a page draws")
    func stackingChangesWhatIsDrawn() throws {
        let unstacked = try renderPNG(page(stacked: false), size: CGSize(width: 800, height: 700), named: "hardware-page-unstacked")
        let stacked = try renderPNG(page(stacked: true), size: CGSize(width: 800, height: 700), named: "hardware-page-stacked")

        // Compares the two renders rather than probing an absolute position.
        //
        // A position assertion would assert nothing here: BOTH configurations
        // auto-scale their own bounds, so the bands land at nearly the same
        // RELATIVE height either way (unstacked 87%/20% of a 25–40 scale;
        // stacked 88.6%/8.6% of a 35–70 one). The thing that actually differs
        // is the whole picture, and a `stacked:` parameter that was accepted
        // and then ignored would produce two identical images.
        #expect(try renderedImagesDiffer(unstacked, stacked, in: chartCanvasProbeRegion))
    }
```

- [ ] **Step 2: Run and watch it fail**

```bash
cd VitalsCore && swift test --filter HardwarePageTests 2>&1 | tail -20
```

Expected: compile error — no `stacked:` parameter.

You will need a two-render comparison helper. Add it to
`Tests/VitalsUITests/RenderHarness.swift`, in the same style as its
neighbours (long doc comment explaining *why* it exists — that is load-bearing
house style here):

```swift
/// True when two renders differ anywhere inside `region`.
///
/// The probe for "did this parameter change anything at all". Position-based
/// probes cannot answer that for a chart whose scale adapts to its own data:
/// two very different decompositions can land at nearly the same relative
/// height, so the honest comparison is against the other render rather than
/// against a coordinate.
@MainActor
func renderedImagesDiffer(_ a: RenderedImage, _ b: RenderedImage, in region: CGRect) throws -> Bool
```

Implement it with the same bitmap loading and region clamping as
`regionHasContent`, comparing `a`'s pixel to `b`'s at each coordinate. Require
that both images share a scale, and fail loudly if they do not — comparing a
1x render against a 2x one would silently report "differ" for every pixel.

- [ ] **Step 3: Add the parameter**

In `HardwarePage`, add `private let stacked: Bool`, add `stacked: Bool` to
`init` **without a default**, placed after `accent:`, and change the chart
construction from `style: .area(stacked: series.count > 1)` to
`style: .area(stacked: stacked)`.

- [ ] **Step 4: Update all five call sites**

Each existing page passes `stacked: true` — CPU clusters, memory bands, GPU
renderer/tiler, storage read/write and network down/up all genuinely sum. Add
`stacked: true` to each of `CPUPage`, `MemoryPage`, `GPUPage`, `StoragePage`
and `NetworkPage`. Also update the existing `page(primaryValue:stats:)` helper
in `HardwarePageTests`.

- [ ] **Step 5: Run and watch it pass**

```bash
cd VitalsCore && swift test --filter HardwarePageTests 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Prove it can fail**

Simulate the parameter being accepted and then ignored: temporarily hardcode
`style: .area(stacked: true)` in `HardwarePage`, leaving the `stacked` property
unread. Confirm `stackingChangesWhatIsDrawn` goes red — both renders become
identical, so nothing differs in the probe region. Restore. Report the output.

This is the regression that matters. A `stacked:` parameter threaded into the
signature but dropped before it reaches `MetricChart` compiles, passes every
other test, and silently sums temperatures.

- [ ] **Step 7: Whole suite and commit**

```bash
cd VitalsCore && swift test 2>&1 | tail -8
```

Expected: 477 tests, 0 failures. Every page's existing render test must still
pass — if one changed, a page's stacking changed, which is a visible regression.

```bash
git add VitalsCore/Sources/VitalsUI/Pages VitalsCore/Tests/VitalsUITests/HardwarePageTests.swift
git commit -m "feat: make HardwarePage's stacking explicit at every call site"
```

---

## Task 7: `ThermometerStrip`

**Files:**
- Create: `Sources/VitalsUI/Components/ThermometerStrip.swift`
- Test: `Tests/VitalsUITests/ThermometerStripTests.swift` (new)

**Interfaces:**
- Produces: `ThermometerStrip(celsius: Double?)`, and
  `static func markerFraction(for celsius: Double) -> Double` (internal, for tests).
- Fixed domain constants: `static let minimumCelsius = 20.0`,
  `static let maximumCelsius = 100.0`.

**Design constraints, all load-bearing:**

- The domain is **fixed at 20–100 °C**. That is the entire point: because the
  scale never moves, a colour always means the same temperature. The chart
  cannot do this — any domain wide enough to make colour meaningful flattens a
  2 °C signal to nothing.
- **No danger zone, no red band, no threshold marks.** The endpoints are a
  display scale chosen by us, not a measurement, and must never read as a
  thermal limit. The spike could not establish this machine's limits.
- The warm end must **not** be `Vitals.Palette.warning`. That red is
  deliberately kept out of the series ramp so it always means "something is
  wrong".
- The gradient runs cool→warm, i.e. **flipped relative to the Kelvin
  colour-temperature scale**, where low Kelvin is orange and high Kelvin is
  blue. A literal Kelvin ramp would paint the hottest readings blue.
- A `nil` reading draws the track with **no marker** — never a marker at zero.

- [ ] **Step 1: Write the failing test**

```swift
import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Thermometer strip")
struct ThermometerStripTests {

    @Test("the marker sits proportionally within the fixed domain")
    func markerFractionIsProportional() {
        #expect(abs(ThermometerStrip.markerFraction(for: 20) - 0.0) < 1e-9)
        #expect(abs(ThermometerStrip.markerFraction(for: 60) - 0.5) < 1e-9)
        #expect(abs(ThermometerStrip.markerFraction(for: 100) - 1.0) < 1e-9)
    }

    /// A reading outside the display scale is clamped, not extrapolated — the
    /// marker must stay on the track rather than being drawn outside it.
    @Test("readings outside the domain clamp to its ends")
    func markerFractionClamps() {
        #expect(abs(ThermometerStrip.markerFraction(for: -40) - 0.0) < 1e-9)
        #expect(abs(ThermometerStrip.markerFraction(for: 400) - 1.0) < 1e-9)
    }

    @Test("a strip with a reading paints its marker")
    func stripWithReadingPaintsMarker() throws {
        let rendered = try renderPNG(
            ThermometerStrip(celsius: 38.8).frame(width: 400, height: 40),
            size: CGSize(width: 400, height: 40), named: "thermometer-with-reading"
        )
        // 38.8 °C is 23.5% along a 20–100 track.
        #expect(try regionHasContent(in: rendered, region: CGRect(x: 84, y: 0, width: 20, height: 40)))
    }

    /// An unmeasurable value must not place a marker at 20 °C, which is what
    /// treating `nil` as zero would look like.
    @Test("a strip with no reading paints no marker")
    func stripWithoutReadingPaintsNoMarker() throws {
        let with = try renderPNG(
            ThermometerStrip(celsius: 38.8).frame(width: 400, height: 40),
            size: CGSize(width: 400, height: 40), named: "thermometer-marker-present"
        )
        let without = try renderPNG(
            ThermometerStrip(celsius: nil).frame(width: 400, height: 40),
            size: CGSize(width: 400, height: 40), named: "thermometer-marker-absent"
        )
        let markerBand = CGRect(x: 84, y: 0, width: 20, height: 40)
        #expect(try regionHasContent(in: with, region: markerBand))
        #expect(try !regionHasContent(in: without, region: markerBand))
    }
}
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd VitalsCore && swift test --filter ThermometerStripTests 2>&1 | tail -20
```

Expected: compile error — `ThermometerStrip` does not exist.

- [ ] **Step 3: Implement**

```swift
    /// Where `celsius` sits along the fixed track, clamped to it.
    ///
    /// Clamped rather than extrapolated: a reading past the end of the display
    /// scale is still a real reading, and drawing its marker off the track
    /// would lose it entirely.
    static func markerFraction(for celsius: Double) -> Double {
        let span = maximumCelsius - minimumCelsius
        return min(max((celsius - minimumCelsius) / span, 0), 1)
    }
```

The view is a rounded track filled with a horizontal `LinearGradient`,
end labels in `Vitals.Typography.label` at secondary emphasis, and a marker
drawn only when `celsius` is non-nil. Use `glassSurface` if the component needs
a surface — do **not** add raw `.glassEffect` calls.

- [ ] **Step 4: Run and watch them pass**

```bash
cd VitalsCore && swift test --filter ThermometerStripTests 2>&1 | tail -20
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Prove the nil test can fail**

Temporarily make the marker draw at `markerFraction(for: celsius ?? 0)`.
Confirm `stripWithoutReadingPaintsNoMarker` goes red. Restore. This is the
`?? 0` the project's founding rule forbids; the test exists to keep it out.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Components/ThermometerStrip.swift VitalsCore/Tests/VitalsUITests/ThermometerStripTests.swift
git commit -m "feat: add a fixed-scale thermometer strip"
```

---

## Task 8: The Sensors page

**Files:**
- Create: `Sources/VitalsUI/Pages/SensorsPage.swift`
- Modify: `Sources/VitalsUI/Design/Tokens.swift` (add `Palette.sensors`)
- Modify: `Sources/VitalsUI/Shell/AppShell.swift:48` (route `.sensors`)
- Test: `Tests/VitalsUITests/SensorsPageTests.swift` (new)

**Interfaces:**
- Consumes: `MetricsStore.sensors`, `MetricsStore.sensorHistory`,
  `SensorSample`, `SensorReading`, `HardwarePage(..., stacked:, ...)`,
  `ThermometerStrip(celsius:)`, `ChartUnit.temperature`.
- Produces: `SensorsPage(store:)`, `SensorsPage.disclosureKey`.

**Page content:**

| Slot | Content |
|---|---|
| Title | "Sensors", `vendorName: nil` (no single device to name — as Network does) |
| Primary | Hottest die temperature via `ChartUnit.temperature.formatted(_:)`; `nil` → em dash |
| Chart | Three unstacked series in this order: **Die, Battery, Storage** |
| Secondary | `ThermometerStrip(celsius: hottestDie)` |
| Stats | Die average · hottest sensor's name · Battery · Storage |
| Specifications | Thermal state, then every reading grouped by family |

**Thermal state goes in Full specifications, as its own row above the groups.**
It is machine-level rather than per-sensor, so it does not belong in the
four key stats, and the template's stats block is four rows. But it must appear
somewhere: it is the only severity signal in this design, and collecting it in
`SensorSample` without ever showing it would ship a field nothing reads.

Render it as the plain state name — `Nominal`, `Fair`, `Serious`, `Critical`.
Do **not** colour it: `Palette.warning` is reserved, and colouring `Fair` amber
would assert a severity judgement Apple's four-level scale does not carry.

**Naming rules — these are the honesty rules, not cosmetics:**

- `gas gauge battery` renders as **Battery**; `NAND CH0 temp` as
  **Storage (NAND)**. Those two are identifiable with confidence.
- `tdie*`, `tdev*` and `TP*` keep their **raw PMU strings**. Mapping them to
  "CPU" or "GPU" would attribute a real measurement to hardware the spike could
  not verify — the same class of error as inventing one.
- Die selection is the prefix `PMU tdie`. If Apple renames them this selects
  nothing, the hottest-die value is `nil`, and it renders as an em dash. That
  is the correct outcome.

**Full specifications is grouped, not flat.** `PMU tcal` reads ~51.9 °C —
higher than any die sensor — while the headline reports the hottest *die* at
~38.8 °C. In a flat list the largest number on the page would sit under a
smaller headline and read as a contradiction. Group under `Die`, `Device`,
`Thermal pressure`, `Battery`, `Storage`, `Other` by the `tdie` / `tdev` / `TP`
/ known-name prefixes. Do **not** annotate `tcal` as a calibration constant —
that is an inference from one spike on one machine.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd VitalsCore && swift test --filter SensorsPageTests 2>&1 | tail -20
```

Expected: compile error — `SensorsPage` does not exist.

- [ ] **Step 3: Add the accent**

In `Sources/VitalsUI/Design/Tokens.swift`, beside the other palette entries:

```swift
        /// The Sensors page's hue. Pink/magenta, chosen to be distinct from
        /// every other page accent AND from `warning` red — that red is kept
        /// out of the series ramp so it always means "something is wrong",
        /// which matters more on a thermal page than anywhere else.
        public static let sensors = Color(red: 0.98, green: 0.55, blue: 0.78)
```

- [ ] **Step 4: Implement the page**

Create `Sources/VitalsUI/Pages/SensorsPage.swift` with static helpers
`hottestDie(in:)`, `dieAverage(in:)`, `displayName(for:)` and `grouped(_:)`
matching the tests above, and a `body` using `HardwarePage` as described in the
table. `grouped` returns an array of a small `SensorGroup` type with `title`
and `readings`. Add `public static let disclosureKey = "sensors.fullSpecs"` —
`PageConsistencyTests` proves these are distinct across pages.

The three chart series must pass `timestamps:` from `store.sensorHistory`, or
gap-breaking silently stops working. Series order is **Die, Battery, Storage**:
the first is the base band and the one the live dot marks.

- [ ] **Step 5: Route the page**

In `Sources/VitalsUI/Shell/AppShell.swift`, add above the `default:` case:

```swift
        case .sensors:
            SensorsPage(store: store)
```

- [ ] **Step 6: Run and watch them pass**

```bash
cd VitalsCore && swift test --filter SensorsPageTests 2>&1 | tail -20
```

Expected: PASS, 6 tests.

- [ ] **Step 7: Prove the headline test can fail**

Temporarily change `hottestDie` to take the max over all readings rather than
only `PMU tdie`-prefixed ones. Confirm `headlineIsHottestDie` goes red with
51.85. Restore. This is the exact confusion the grouping exists to prevent.

- [ ] **Step 8: Whole suite and clean build**

```bash
cd VitalsCore && swift test 2>&1 | tail -8
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

Expected: 487 tests, 0 failures; `0` warnings.

- [ ] **Step 9: Verify in the running app**

```bash
cd ~/Developer/Vitals && ./scripts/build-app.sh && open build/Vitals.app
```

Select Sensors. **Confirm through the accessibility API which page is selected
before describing any capture** — an agent on this project once reported a
capture of a different page. Confirm: a real headline temperature; three
separated bands in the chart rather than one summed band; both axis labels;
the thermometer marker roughly a quarter along its track; and Full
specifications grouped with `PMU tcal` outside the `Die` group. Report what you
saw with a screenshot.

- [ ] **Step 10: Commit**

```bash
git add VitalsCore/Sources/VitalsUI VitalsCore/Tests/VitalsUITests/SensorsPageTests.swift
git commit -m "feat: add the Sensors page"
```

---

## Final verification

- [ ] **Whole suite, twice**, both green. A flaky render test that passes once is not passing.
- [ ] **Clean build** prints `0` warnings.
- [ ] **Walk the app**: every existing page still renders, and none of their charts changed shape — Task 6 touched all five, and Task 4 touched the maths under all of them.
- [ ] **Update `AGENTS.md`**: move Sensors from "Not built yet" to complete, and record that fans and component power remain unbuilt with their reasons.
- [ ] **Update the ledger** `.superpowers/sdd/progress.md` with each task, what it found, and anything surprising.
