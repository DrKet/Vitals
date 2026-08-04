# Battery page — design

A Battery page in the Hardware section, modelled on Apple's Battery settings
and its battery-health panel.

Approved by the owner 2026-08-04. Every number below was measured on this
machine (Mac14,9) during the design, not assumed.

## Prerequisite

Builds on `HardwarePage(..., stacked:, ...)` and `MetricChart.fillOpacity`,
which exist only on branch `sensors-spike` (PR #3), itself stacked on
`visual-polish` (PR #2). Branch from `sensors-spike`, not from `main`.

## What the probe established

All of this is public API — unlike the Sensors milestone, no private framework
and no spike were needed. But four findings shape the design, and three of them
are traps.

**1. Two Apple APIs disagree about battery health.** Seconds apart on the same
machine: `system_profiler SPPowerDataType` reports `Condition: Normal`, while
`IOPSGetPowerSourceDescription` reports `BatteryHealth = "Check Battery"`.
`system_profiler` is the one that agrees with Settings, so it is the source of
truth here. **Do not switch to the IOPS key because it is easier to read** — it
would tell a user with a healthy battery that it needs service.

**2. Maximum Capacity cannot be computed.** Apple reports **95%**. The two
obvious formulas from the raw registry values both disagree:
`AppleRawMaxCapacity / DesignCapacity` = 5492/6075 = 90.4%, and
`NominalChargeCapacity / DesignCapacity` = 5642/6075 = 92.9%. Apple's
computation is undocumented. So Maximum Capacity is **read from
`system_profiler`, never derived** — a figure labelled "Maximum Capacity" that
disagrees with Settings is worse than no figure at all.

**3. `Amperage` is a signed value delivered unsigned.** Measured discharging:
`18446744073709550565`, which is −1051 mA in `UInt64` wraparound. Measured
charging: `4090`, plain and positive. So the trap appears **only while
discharging** — an implementation that reads it naively looks perfect on a
plugged-in development machine and produces absurd numbers in the field.
Reinterpret via `Int64(bitPattern:)`.

**4. macOS defines "low battery" itself.** `IOPSGetBatteryWarningLevel()`
returns `none` / `early` / `final`. Used instead of a percentage we choose, for
the same reason `ProcessInfo.thermalState` governs the Sensors page: the
platform decides what counts as a warning.

## Scope

**In:** live power draw, charge, time remaining, health, cycle count, and the
supporting electrical detail, on machines that have a battery.

**Out:** Apple's 24-hour and 10-day energy-usage history. That requires
persisting samples across launches; Vitals holds 600 in-memory samples and only
samples while a page is open. Half-building it would produce a graph that
silently covers "since you opened this window" while looking like Apple's.

## 1. Data layer

Two sources on two cadences, because they change at wildly different rates.

**Live, slow cadence — `AppleSmartBattery` in the IORegistry.** Charge
percentage, voltage, amperage, time remaining, charging state, external power,
temperature. Slow rather than fast: the gas gauge itself only updates every few
seconds, so a 1 Hz sampler would redraw identical values.

```swift
public struct BatterySample: Sendable, Equatable {
    /// Magnitude of power moving in or out, in watts. See "Power is charted as
    /// a magnitude" below for why this is never signed.
    public let watts: Double
    public let chargePercent: Int
    public let isCharging: Bool
    public let isExternalPowerConnected: Bool
    /// `nil` when the gas gauge has not settled — macOS reports 65535 as a
    /// sentinel for "unknown", which must never render as 65535 minutes.
    public let minutesRemaining: Int?
    public let voltage: Double
    public let temperatureCelsius: Double
    public let warningLevel: BatteryWarningLevel
    public let isLowPowerMode: Bool
}

public enum BatteryWarningLevel: Sendable, Equatable {
    case none, early, final
}
```

**Health, at launch — `system_profiler SPPowerDataType`, on `HardwareProfile`.**
Condition, Maximum Capacity, cycle count. This mirrors how `HardwareProfile`
already shells out to `system_profiler` for memory, so it is an established
pattern rather than a new dependency. These values change over months; reading
them once at launch is correct.

**Absence** is handled at three levels, matching the project's existing rule
that inapplicable hardware is absent rather than shown empty:

- No battery at all (Mac mini, Studio, Pro) → the sidebar item never appears.
- Battery present, one field unreadable → em dash for that field.
- IORegistry unreachable → the sampler throws and the page reads "Unavailable"
  rather than showing zeros.

## 2. The sidebar becomes conditional

`SidebarSection.groups` is a hardcoded static list today. It becomes a function
taking the hardware profile, so Battery appears only on machines that have one.

This is the change with the widest blast radius in the milestone: `AppShell`
and the sidebar tests move with it. It is worth doing rather than rendering a
permanently empty page, because "inapplicable hardware is absent rather than
shown empty" is the project's own stated principle and a permanently empty
Battery page on a Mac Studio is exactly what it warns against.

Sensors is deliberately **not** made conditional in the same change. It only
just shipped, and bundling a second page into this refactor would make the
diff harder to reason about. Noted as a follow-up.

## 3. The page

| Slot | Content |
|---|---|
| Title | "Battery", `vendorName: nil` |
| Primary | Live power draw, e.g. `11.6 W` |
| Chart | One series: watts over time, `stacked: false` |
| Secondary | `BatteryLevelBar` — glyph, percentage, level bar |
| Key stats | Charge and state · Time remaining · Maximum capacity · Cycle count |
| Specifications | Condition with status dot, design and current capacity in mAh, voltage, temperature, adapter status, device name |

**Power is charted as a magnitude, never signed.** Current flows out when
discharging and in when charging. Plotting −11.6 W and +45.3 W on one axis
would conflate two different physical events, and `.absolute` bounds are
zero-based so negatives would clamp to zero and simply vanish. The chart shows
how much power is moving; the stats say which way.

**The serial number is omitted entirely**, though `AppleSmartBattery` exposes it
and System Information displays it. It is a uniquely identifying string with no
monitoring value — it never changes and says nothing about how the battery is
doing — and it would appear in every screenshot of the page.

### `BatteryLevelBar`

A battery glyph, the percentage, and a horizontal level bar. Unlike the Sensors
thermometer strip, its domain needs no invented endpoints: charge is a bounded
0–100% quantity, so the bar is honest by construction.

Its colour carries three states, each from a system signal rather than our
judgement:

| State | Source | Colour |
|---|---|---|
| Normal | — | `Palette.battery` green |
| Low Power Mode | `pmset` / `lowpowermode` | Yellow |
| `early` warning | `IOPSGetBatteryWarningLevel()` | Amber |
| `final` warning | `IOPSGetBatteryWarningLevel()` | `Palette.warning` red |

Low Power Mode yellow matches Apple's own convention for that state. The red is
**the first legitimate use of `Palette.warning`**: it was deliberately kept out
of the series ramp so it always means "something is wrong", and a battery at
its final warning is precisely that. Precedence when both apply: warning level
wins over Low Power Mode, because a battery about to die matters more than a
power-saving preference.

### Condition dot

A coloured dot beside Condition in Full specifications, echoing Apple's panel.
Green for `Normal`, `Palette.warning` for anything else. The verdict comes
verbatim from `system_profiler` — this renders Apple's judgement, it does not
form one.

### Accent

A new `Palette.battery`, green at roughly 100° hue. That is the largest
genuinely free gap in the ramp — about 50° from network's 43° and from
storage's 156° — and green-for-battery is a convention nobody has to learn.
`TokensTests` already proves hue distinctness; the new entry joins those checks.

## 4. Testing

- **Pure parsing** carries the coverage: the `Amperage` wraparound in both
  directions (`4090` → +4.09 A, `18446744073709550565` → −1.051 A), the 65535
  sentinel becoming `nil`, and the `system_profiler` health fields.
- **Colour selection** is a pure function of (warning level, low power mode) —
  four cases plus the precedence rule.
- **Render**: the page renders with a live store; the level bar paints at the
  right proportion; a `nil` reading paints no fill rather than an empty bar at 0.
- **Sidebar**: Battery is absent from `groups` when the profile reports no
  battery, present when it does.
- **Unavailability**: a throwing sampler yields em dashes throughout, never a
  zero.

Every assertion must be watched failing before it is trusted. Eight tests
written from plans on this project have turned out to assert nothing.

## Non-goals

- Apple's 24-hour / 10-day energy history (needs cross-launch persistence).
- Making Sensors conditional in the sidebar (follow-up).
- Any control over battery behaviour — Vitals is a monitor, and toggling Low
  Power Mode or charging settings belongs to Settings.
