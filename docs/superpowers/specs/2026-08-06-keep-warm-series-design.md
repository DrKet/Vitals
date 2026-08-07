# Keep the fast chart series warm

Switching to a hardware page shows a blank or half-filled chart for a second or
two. Sampling is subscription-driven, so a series is only sampled while a page
showing it is open; leave that page and its sampling stops, so on return the
recent slice of the chart is empty until fresh samples accumulate (one per
second, and a rate needs two). This keeps the cheap fast series sampling for the
whole session so those switches are instant.

Validated as a prototype the owner tried in the running app before this was
written; it "feels pretty good", so this formalises exactly that behaviour.

## Scope

Keep five series warm: `cpu`, `memory`, `gpu`, `network`, `diskIO`. Nothing
else changes — not the samplers, not the cadences, not the charts, not the
staleness rules.

## Decisions

Both settled with the owner.

**Warm set is the five cheap fast chart series only.** They sample at 1 Hz and
are inexpensive (Mach/sysctl/IOKit reads, no subprocess, no process-table
walk). Deliberately excluded:
- `processes` — walks the whole process table; expensive, and it is the one
  thing the subscription-driven design exists to keep off an idle machine.
- `sensors`, `battery` — the 5-second slow cadence; warming them saves little
  and battery/sensors are read less often for good reason. Sensors stays lazy
  and slow on first open, accepted for now.
- `storage` (volume capacity) — has no chart and its live field never expires,
  so there is nothing to keep warm.

**Always warm while the app runs.** No backoff for Low Power Mode or window
occlusion in this version. The cost is five cheap reads per second, which is
what makes the switch instant; power-awareness can be added later if the
battery impact ever proves noticeable. Keeping it out now avoids a mode-check
and a state transition that would need their own tests for a cost that is
likely negligible.

## Architecture

Three small pieces, all in existing files.

**`MetricsStore.keepWarmSeries: Set<SeriesKey>`** — the warm set as a named
`static` constant: `[.cpu, .memory, .gpu, .network, .diskIO]`. Naming it makes
the *exclusions* explicit and testable rather than buried in a list of view
modifiers.

**`MetricsStore.keepWarm() async`** — subscribes to every series in
`keepWarmSeries` concurrently and runs until cancelled. Implemented as a
`withTaskGroup` that spawns one `stream(_:)` per series; `stream` already loops
until its subscription ends, so the group simply never returns until the caller
is cancelled, at which point the group cancels every child stream.

**`AppShell`** calls it once, from the root view:
`.task { await store.keepWarm() }`. The root view lives for the whole session,
so the warm subscriptions do too. This replaces nothing — it is one added
modifier.

**Why this is safe alongside page subscriptions.** A hardware page still calls
its own `store.stream(_:)`. When a warm series' page is open, that series has
two subscribers (the warm one and the page's). `MetricsStore.apply` is already
idempotent on the sample's timestamp — it drops a sample whose timestamp it has
already applied — so the same tick fanned out to both subscribers is stored
once. The engine likewise fans one sample to all subscribers, so double
subscription costs nothing beyond the subscription bookkeeping. A regression
test for exactly this overlap already exists (`apply`'s idempotency, exercised
by the Overview-plus-hardware-page case).

**Bonus, not a separate feature:** because a warm series keeps ticking, its
live field is continuously re-armed, so the staleness watch never expires it.
The headline reading on a warm page is therefore already current on switch, not
an em dash that fills in. This falls out of the warm subscription; no extra
code.

## Testing

Two assertions carry the weight; both are watched failing first.

1. **`keepWarmSeries` excludes the costly and slow series.** Assert the set
   does not contain `.processes`, `.sensors`, `.battery`, or `.storage`, and
   does contain the five fast ones. This is the load-bearing invariant — the
   whole point is to warm only the cheap series and never the process-table
   walk. Mutation check: adding `.processes` to the set reddens it. A bare
   "the set equals itself" assertion would prove nothing; the exclusions are
   what matter.

2. **`keepWarm()` actually sustains sampling with no page open.** With a fresh
   `MetricsEngine` + `MetricsStore` and no page subscribed, run `keepWarm()` in
   a task, wait (via the suite's existing `waitUntil`) until the engine's
   `activeSeries` contains every series in `keepWarmSeries`, assert that, then
   cancel. Mutation check: if `keepWarm` subscribed to nothing (or the wrong
   set), `activeSeries` never reaches the warm set and the wait times out red.
   `keepWarm` never returns on its own, so the test drives it exactly as
   `AppShell` does — start in a task, observe the effect, cancel — matching how
   `MetricsStoreTests` already tests `stream`.

The change adds no stored property to a `SystemMetrics` struct, so the
incremental-build SIGSEGV trap does not apply — but the suite is still run from
a clean build once, per the standing rule, and because a render/GUI session is
involved for the wider suite.

## Out of scope

Power-aware backoff (Low Power Mode, occlusion); warming or burst-filling
Sensors; any change to cadences, samplers, charts, or the staleness thresholds.
