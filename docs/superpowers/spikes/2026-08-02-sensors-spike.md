# Sensors spike — `IOHIDEventSystemClient` on Apple Silicon

Run 2026-08-02 on **Mac14,9 / Apple M2 Pro / macOS 26.2 / arm64**, unprivileged
(uid 501). Reproduce with `swiftc -O scripts/spike-sensors.swift -o /tmp/sp`
then `/tmp/sp enumerate` or `/tmp/sp watch 30`.

The ledger flagged this as the highest-risk item on the roadmap, with a specific
warning: *"A model will very plausibly invent an API that compiles and returns
nothing."* So the probe **enumerates rather than assumes** — it matches on the
Apple vendor usage page alone and sweeps every event type 0...63, rather than
filtering by a guessed usage/type pair. And plausible numbers were not accepted
as proof; see "Validation" below.

## Verdict

**Temperatures: feasible, now.** Real, unprivileged, no entitlement, no TCC
prompt, and validated against physical reality.

**Fans: not available through this API.** Needs its own spike against AppleSMC.

**Component power: not attempted.** The spec's §4.6 routes it through the
IOReport Energy Model channel, a completely different API. Separate spike.

**One finding materially constrains the UI** — sensors have no unique identity.
See "The identity problem", which is the part worth reading before planning.

## What works

All six private symbols resolve from `IOKit.framework` via `dlsym`:
`IOHIDEventSystemClientCreate`, `…SetMatching`, `…CopyServices`,
`IOHIDServiceClientCopyProperty`, `IOHIDServiceClientCopyEvent`,
`IOHIDEventGetFloatValue`.

`dlsym` rather than linking, deliberately: these are in no public header, so
linking needs a C shim — and a symbol going missing on a future OS should be a
recoverable `nil` at runtime, not a build or launch failure.

Matching on `{"PrimaryUsagePage": 0xff00}` returns **71 services**. Only two
usages answer any event type in 0...63:

| Usage | Services | Event type | Result |
|---|---|---|---|
| `0x0005` | 64 | 15 (`kIOHIDEventTypeTemperature`) | real °C |
| `0x0004` | 1 | 12 | constant `0.000` |

The field id is `IOHIDEventFieldBase(type)` = `type << 16`.

Named temperature sensors include `PMU tdie0`…`tdie10` (die), `PMU tdev1`…`tdev8`,
`PMU TP0s`/`TP1g`/`TP1s`/`TP2g`/`TP2s`/`TP3g`, `PMU tcal`, `NAND CH0 temp`, and
six `gas gauge battery`. Idle values sat at 28–52 °C.

## Validation — why these are real and not a stub

Plausible magnitudes prove nothing: a stale cache, a misread field, or a
hardcoded stub all produce "37.1". The test that discriminates is whether the
values **track physics**. Sampling the 26 `PMU tdie*` sensors once a second:

| Phase | Mean of 26 sensors |
|---|---|
| Idle, 10 s | 36.92 → 37.02 (flat) |
| CPU burn on 10 cores | 37.02 → 42.26, monotonic |
| After burn (peaked ~47) | 46.36 → 45.42, monotonic decay |

A +5.3 °C rise beginning exactly when load started, across 26 independent
sensors, followed by monotonic decay when it stopped. That is a real
measurement.

> Process note: the burn outlived its `kill` by ~30 s because `jobs -p` did not
> capture the subshell PIDs. Ten spinning loops were found via `ps` and killed;
> that is why the peak reads ~47 °C rather than the ~42 °C the 46 s window
> shows. Capture PIDs with `$!` per background job, not `jobs -p`, next time.

## The identity problem — read this before planning the page

**No unique identifier exists for a sensor.** Measured across all 71 services:

| Key | Coverage | Distinct |
|---|---|---|
| `RegistryID` | absent on all | — |
| `UniqueID` | absent on all | — |
| `Product` | 64/71 | 29 |
| `LocationID` | 70/71 | 38 |

Restricted to the 64 usable temperature sensors: 29 distinct `Product`, 36
distinct `LocationID`, and **36 distinct `Product`+`LocationID` composites — 28
of the 64 collide.** `LocationID` does not help, because it is not independent:
`1414541427` is `0x54503073`, ASCII `"TP0s"` — a FourCC of the sensor's own
name.

So two sensors can share name *and* location and still be distinct hardware.

This collides head-on with AGENTS.md's rule that *"attributing a real
measurement to the wrong hardware is the same class of error as inventing
one"*. Concretely:

- Labelling duplicates `PMU tdie1 #1` / `#2` **would be fabrication.** Service
  order is stable within a process (verified across two consecutive
  `CopyServices` calls), but nothing establishes that `#1` is the same physical
  sensor across launches or reboots, and nothing maps either to a location a
  user could name.
- The honest options are (a) aggregate duplicates under one name and report the
  max plus a count, or (b) curate a small named subset and show only sensors
  that can be attributed. Both are defensible; it is a design call.

64 raw sensors is in any case far too many to list, so curation is needed
regardless of the identity question.

## Open questions for the design phase

1. **Which sensors does a user actually want?** `tdie*` are die temperatures —
   the plausible headline. `tcal` reads ~52 °C at idle and is likely a
   calibration reference, not a thermal reading; showing it as "temperature"
   would be attributing a number to something it does not measure.
2. **Aggregate or curate** the duplicates (above).
3. **Fans** need an AppleSMC spike. The 2 services at usage `0x000b` are a
   tempting match for this machine's 2 fans but produce no event for any type
   0...63.
4. **Power** needs an IOReport spike.
5. **Intel Macs** take an entirely different path (SMC keys) per spec §4.6.
   This spike says nothing about them, and nothing here should be assumed to
   generalise.
6. **Private-API fragility.** Every call must degrade to `nil` rather than
   trap, and the sampler must throw rather than return zeros — the existing
   `SystemMetrics` contract already requires this.

## Recommendation

A Sensors page limited to **temperatures** is buildable now and is honest. Fans
and power should not be scoped into that milestone until their own spikes come
back — a page promising "temperatures, fans and power" that ships with only one
of the three is worse than a page that says what it measures.
