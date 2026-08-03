# Sensors page — design

Temperatures only. Grounded in
`docs/superpowers/spikes/2026-08-02-sensors-spike.md`, which proved the readings
are real on this machine and surfaced the two constraints that shape this
design: sensors have no unique identity, and the real dynamic range is tiny.

Approved by the owner 2026-08-02.

## Prerequisite: this depends on the visual-polish branch

**Do not start implementing this against `main`.** Section 2 extends
`ChartGeometry.axisMaximum`, `axisLabel`, `NiceBound` and `niceUpperBound`, and
§2a changes the `HardwarePage` signature. None of that API exists on `main` —
all of it is on branch `visual-polish`, open as PR #2 and not yet merged
(verified: `git grep niceUpperBound main` finds nothing;
`Metrics.chartMaxHeight` and `ReadoutPlacement` are likewise absent).

So implementation must either wait for PR #2 to merge, or branch from
`visual-polish` rather than `main`. Branching from `main` would produce a plan
whose every chart task fails to compile.

## Scope

**In:** temperatures via `IOHIDEventSystemClient`, on Apple Silicon.

**Out, deliberately:** fans (the spike proved they are not reachable through
this API — the two services at usage `0x000b` produce no event for any type
0...63, so they need their own AppleSMC spike); component power (spec §4.6
routes it through IOReport, a different API entirely); Intel Macs (SMC keys, a
different path the spike says nothing about).

A page promising "temperatures, fans and power" that ships one of the three is
worse than a page that states what it measures. The sidebar item is already
present as a placeholder, so nothing regresses by scoping down.

## The two constraints from the spike

**No unique identity.** `RegistryID` and `UniqueID` are absent on every
service. `Product` covers 64/71 with 29 distinct values; adding `LocationID`
still leaves 28 of the 64 temperature sensors colliding, because `LocationID`
is only a FourCC of the name (`1414541427` is ASCII `"TP0s"`). Two sensors
share name *and* location and are still distinct hardware.

**A tiny dynamic range.** Across a 75-second capture spanning a full CPU load
ramp, the hottest die moved **2.13 °C** (36.69 → 38.82). Storage quantises to
whole degrees; the battery moved 0.3 °C.

## 1. Data layer — `SystemMetrics`

`TemperatureSampler` resolves six private symbols from `IOKit.framework` with
`dlsym` (not linking: they appear in no public header, and a symbol vanishing
on a future OS must be a recoverable `nil`, not a launch failure). It matches
`{"PrimaryUsagePage": 0xff00}` and reads event type 15 at field `15 << 16`.

```swift
/// One named temperature, aggregated across every sensor reporting that name.
public struct TemperatureReading: Sendable, Equatable {
    /// The raw `Product` string, e.g. "PMU tdie0". Never a friendly label —
    /// see "Naming" below.
    public let name: String
    /// The hottest of the instances sharing `name`.
    public let celsius: Double
    /// How many sensors reported it. A measured fact, not metadata: it is the
    /// honest answer to "which sensor is this", which has no better answer.
    public let sensorCount: Int
}

public struct TemperatureSample: Sendable, Equatable {
    public let readings: [TemperatureReading]
    /// Apple's own severity signal. The ONLY severity source in this design —
    /// see "Severity" below.
    public let thermalState: ProcessInfo.ThermalState
}
```

**Aggregation rule: group by `name`, take the max, count the instances.** Max
rather than mean because a thermal readout is about the hottest point, and mean
would understate it. Grouping rather than indexing because labelling duplicates
`#1`/`#2` would be fabrication: service order is stable within a process
(verified), but nothing establishes that `#1` is the same physical sensor
across launches, and nothing maps either to a location a user could name.

**The sampler throws** when the client cannot be created, a symbol is missing,
or no service yields a reading. It never returns an empty or zeroed sample.
That is what makes the page render "Unavailable" on an Intel Mac rather than
0 °C.

**`PMU tcal` is not filtered out of the data.** It appears in Full
specifications with everything else. It is excluded only from the die aggregate
and the headline, because it read exactly `51.850` in every sample of every run
— a calibration constant, not a live temperature. Excluding it from the data
entirely would be hiding a reading; treating it as a die temperature would be
attributing a number to something it does not measure.

## 2. Shared chart changes

Two changes to code five other pages use. Both close latent traps rather than
merely serving this page.

### 2a. `HardwarePage` takes an explicit `stacked:` parameter

Today it infers `style: .area(stacked: series.count > 1)`. That is correct for
all five existing pages — CPU clusters, memory bands, read/write, up/down all
genuinely sum — and wrong the moment a page's series are not additive. A
stacked die at 38 °C and battery at 28 °C would draw a band at 66 °C, a value
no sensor reported.

Add the parameter with **no default**, so all five existing call sites must
state their intent. A default would leave the trap armed for the next
non-additive page, which is exactly how the axis label reached the Overview
tiles in the previous milestone.

### 2b. Charts gain a lower bound, via a new `ChartUnit` case

A temperature is an interval quantity with no meaningful zero for charting;
throughput is a ratio quantity where zero is real and meaningful. That
difference belongs in the unit, not in a flag at the call site:

```swift
public enum ChartUnit: Sendable, Equatable {
    case fraction
    case absolute(suffix: String)
    case temperature          // NEW
}
```

`ChartGeometry` gains one source of truth for both ends:

```swift
public static func bounds(for stacked: [[Double]], unit: ChartUnit)
    -> (lower: Double, upper: Double)
```

- `.fraction` → `(0, max(peak, 1.0))` — unchanged behaviour.
- `.absolute` → `(0, niceUpperBound(atLeast: max(peak, absoluteFloor)).value)`
  — unchanged behaviour.
- `.temperature` → the outward-rounded pair below.

`upperBound(for:unit:)` stays and delegates to `bounds(...).upper`, so every
existing caller and every existing test is untouched.
`points(_:in:lowerBound:upperBound:)` takes the lower bound with a default of
`0`, so existing callers are likewise unchanged.

**The temperature bound rule, and why it is not the defect Task 3 just fixed.**
A baseline tracking raw min/max would move every tick and reshape the chart on
steady readings — precisely the defect the previous milestone removed from
absolute charts. So the bounds round *outward to multiples of 5*, across all
series on the chart:

```
lower = floor(min / 5) * 5;  if lower == min { lower -= 5 }
upper = ceil(max / 5) * 5;   if upper == max { upper += 5 }
```

The strict comparisons keep the data off the axis and guarantee a span of at
least 5 °C (10 °C in the degenerate all-flat case). The scale then changes only
when a reading crosses a 5 ° boundary, not every tick.

Worked against the captured data: die/battery/storage spanning 28.5–38.82 gives
**25–40 °C**. The die's 2.13 °C swing occupies 14% of the height instead of the
4% a zero-based chart gives it.

### 2c. What the new `ChartUnit` case must do everywhere it is switched on

Adding a case to `ChartUnit` touches three existing switches. All three need an
explicit answer, or an implementer will guess:

**`ChartUnit.formatted(_:)`** — `.temperature` formats as one decimal place
plus a degree suffix: `38.8 °C`. Not the `%.2f` `.absolute` uses (`38.82 °C`
implies a precision the sensor does not have — readings arrive quantised to
~0.09 °C on this hardware, and storage to whole degrees), and not `%.0f`
(which would hide the 2 °C signal this page exists to show). This is what the
crosshair readout prints.

**`ChartGeometry.axisMaximum(for:unit:)`** — currently `guard case .absolute`.
It must return the upper bound for `.temperature` too, so the chart labels its
ceiling. `NiceBound.decimals` is `0` for a multiple of 5, which is correct:
the ceiling is `40 °C`, not `40.0 °C`.

**`ChartGeometry.axisLabel(_:unit:)`** — currently `guard case .absolute(let
suffix)`. For `.temperature` it returns the value with a `°C` suffix.

**Both ends are labelled** on a temperature chart, which needs one new call
alongside `axisMaximum`:

```swift
/// The lower end of a chart's scale, or `nil` when that end is a known zero
/// and therefore not worth the ink.
public static func axisMinimum(for stacked: [[Double]], unit: ChartUnit) -> NiceBound?
```

It returns `nil` for `.fraction` and `.absolute` — both are zero-based, and a
"0" label restates what a baseline already says — and the lower bound for
`.temperature`. `MetricChart` draws it at the plot rect's bottom-leading
corner, mirroring where the maximum is drawn.

## 3. UI

`SensorsPage` uses the standard `HardwarePage` template — it supplies data and
the two view-builder slots and nothing else.

| Slot | Content |
|---|---|
| Title | "Sensors", no vendor mark (like Network — there is no single device to name) |
| Primary value | Hottest die temperature, e.g. `38.8 °C`; `—` when unavailable |
| Chart | Three unstacked series: die (hottest), battery, storage |
| Secondary | `ThermometerStrip` (below) |
| Key stats | Die average · hottest sensor's name · battery · storage |
| Full specifications | Every distinct sensor: name, reading, instance count |

"Hottest sensor's name" is a stat because it is a measured fact that costs
nothing and answers a real question. It avoids restating the 40pt headline
number in the stats block — the redundancy that got the axis label suppressed
on Overview tiles last milestone.

### `ThermometerStrip`

A horizontal track over a **fixed 20–100 °C domain**, carrying a cool-to-warm
gradient, with a marker at the current hottest die temperature and both
endpoints labelled.

Fixed is the whole point: because that scale never moves, a colour always means
the same temperature. The chart cannot do this — the mockup showed that any
domain wide enough to make colour meaningful flattens a 2 °C signal to nothing
— so the two split the work, and the strip fills a `secondary` slot that sits
empty on four other pages.

Constraints on it:

- **No danger zone, no red band, no threshold marks.** The endpoints are a
  display scale chosen by us, not a measurement, and must never be presented as
  a thermal limit. The spike could not establish this machine's limits.
- The warm end must not be `Palette.warning`. That red is deliberately kept out
  of the series ramp so it always means "something is wrong"; spending it as a
  scale colour costs that signal, and it matters more on a thermal page than
  anywhere else.
- The gradient runs cool→warm, i.e. **flipped relative to the Kelvin
  colour-temperature scale**, where low Kelvin is orange and high Kelvin is
  blue. A literal Kelvin ramp would paint the hottest readings blue.

### Accent

A new `Palette.sensors` in the pink/magenta family — distinct from CPU blue,
Memory purple, GPU orange, Storage mint, Network amber, and from `warning` red.
It leads the chart ramp via `seriesColors(startingAt:)` and matches the page's
future Overview tile.

## 4. Naming

`gas gauge battery` renders as **Battery** and `NAND CH0 temp` as **Storage
(NAND)** — those two are identifiable with confidence.

`tdie*`, `tdev*` and `TP*` keep their **raw PMU strings**. Mapping them to
"CPU" or "GPU" would attribute a real measurement to hardware the spike could
not verify — the same class of error as inventing one, and the reason the GPU
page already withholds readings it cannot attribute.

The die group is selected by the prefix `PMU tdie`. This is a match on an
undocumented vendor string and will silently select nothing if Apple renames
them; in that case the hottest-die value is `nil` and renders as an em dash,
which is the correct outcome.

## 5. Severity

`ProcessInfo.thermalState` is the only severity signal in this design. It is
documented, Apple-provided, and four-valued (nominal / fair / serious /
critical), and it read `nominal` correctly on an idle machine during the spike.
`pmset -g therm` had recorded nothing and is not used.

Nothing else in the page may imply severity: no colour thresholds, no red
readings, no "hot" labels derived from a number we chose.

## 6. Cadence and subscription

Registered on the **slow** cadence — temperatures move ~2 °C per minute under a
full load ramp, so a fast cadence would spend power to redraw identical values.
Sampling stays subscription-driven via `.task { await store.stream(.temperatures) }`,
so nothing is sampled unless the page is open, and history genuinely contains
gaps. The three `ChartSeries` must therefore pass `timestamps:`, or gap-breaking
silently stops working for this page.

## 7. Testing

- **Pure aggregation** (group by name → max + count) is where the coverage
  goes: fixtures with duplicate names, a single name, and an empty input.
- **`bounds(for:unit:)`** for `.temperature`: the worked 28.5–38.82 → 25–40
  case, the on-a-boundary cases that trigger the `-= 5` / `+= 5` branches, the
  degenerate all-flat case, and — critically — proof that `.fraction` and
  `.absolute` are byte-identical to today.
- **Render**: the page renders with a live store; the thermometer strip paints;
  the chart draws three separate bands and **not** a stacked total.
- **Unavailability**: a throwing sampler yields "Unavailable"/em dashes
  throughout and never a zero.
- Every one of these must be watched failing before it is trusted. Five tests
  in the previous milestone stayed green when the exact defect they guarded was
  reintroduced.

## 8. Risks

- **Private API.** Every call must degrade to `nil` rather than trap; the
  sampler throws rather than returning zeros. `Int(Double.infinity)` traps in
  Swift, so any numeric conversion needs a finite check — the previous
  milestone hit exactly this.
- **Prefix matching on vendor strings** is brittle by nature. Accepted, because
  the failure mode is a missing reading rather than a wrong one.
- **Other constant-valued sensors** may exist besides `tcal` and would be
  indistinguishable from live ones in a single sample. Not detectable at
  runtime without history; out of scope, and harmless because such sensors
  appear only in Full specifications.
- **Machine-specific findings.** Every number in the spike came from one
  Mac14,9. Sensor names, counts and families will differ on other Apple Silicon
  models, so nothing may hard-code the 64-sensor count or the specific names
  beyond the documented prefixes.

## Non-goals

- Fans, component power, Intel Macs (each needs its own spike).
- Per-sensor physical identity — proven unavailable.
- An Overview tile for Sensors. The accent is chosen so one can be added later
  without rework, but it is not in this milestone.
