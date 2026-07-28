# Processes Table — Design

**Date:** 2026-07-28
**Milestone:** M1-B-3
**Status:** Approved

## Goal

A read-only, live process table — the "what is eating my machine" view that spec
§4.7 describes and that the project's original brief asked for when it said to
bring Windows Task Manager's functionality over.

## Scope

Spec §4.7 describes far more than one plan can carry: Apps/Background/System
grouping, a flat Details toggle, a process tree, heat-map shading, a context menu
(Quit, Force Quit, Suspend, Resume, `renice`, Sample, Spindump, Reveal, Inspect),
an inspector sheet, and sixteen columns.

This slice is **the read-only table only**. It touches nothing destructive, which
keeps every safety question that killing a process raises out of the first
increment.

### Out of scope for this slice

- Context menu and any process action (Quit, Force Quit, Suspend, Resume, renice)
- The process tree and Apps/Background/System grouping — classifying a macOS
  process as "App" versus "Background" is a design problem in its own right
- The inspector sheet (open files, ports, per-thread CPU, code signature,
  environment)
- Columns the sampler cannot feed: status, compressed memory, ports, per-process
  network, per-process GPU, energy impact, sandbox status. GPU and energy need
  the privileged helper (M3); per-process network needs elevated access.

## Available data

`MetricsEngine` already publishes `.processes` at the `.slow` cadence, carrying:

```swift
public struct ProcessSeriesSample: Sendable {
    public let processes: [ProcessSnapshot]
    public let cpuUsage: [pid_t: Double]   // 1.0 == one core saturated
}
```

`ProcessSnapshot` provides `pid`, `parentPID`, `name`, `userID`,
`memoryFootprintBytes?`, `cpuTimeSeconds?`, `threadCount?`, `diskBytesRead?`,
`diskBytesWritten?`, and `architecture` (native / translated).

No new sampling is required. CPU-percentage derivation is already done by
`ProcessCPUTracker` inside the sampler, and a process whose CPU time is
unreadable simply has no entry in `cpuUsage` — already the shape this design
needs.

## Decisions

### 1. Live updates: values refresh, order holds

Rows re-sort only when the sort descriptor changes or the view appears. Between
those, values update in place, exited processes are removed from their slot, and
newly-started processes append at the end rather than being inserted in sorted
position.

**Why:** at a 5-second tick, re-sorting every tick moves rows a long way and
makes the table genuinely hard to read. This is what makes Activity Monitor's
default tolerable, and Windows Task Manager deliberately avoids the alternative.

**Cost, accepted:** ordering can be a few seconds stale, so a process that just
spiked may sit mid-table until a header is clicked. If that grates in use, the
follow-up is a small re-sort affordance, not a change to this rule.

### 2. Unreadable values: shown, dashed, sorted last

Every process appears. Unreadable cells render as an em dash. When sorting by a
column, unknowns cluster at the far end as a distinct group rather than mixing in
as zeros.

**Why:** M1-A measured 197 of 592 live processes with unreadable CPU time —
typically other users' and root's. Sorting them as zero would assert they are
idle, which is the exact defect that made `cpuTimeSeconds` Optional in the first
place. Hiding them would make a view titled "Processes" omit a third of them.

**Cost, accepted:** the CPU column will not sum to the machine's actual total.

### 3. Heat map: relative to visible rows

Numeric cells in the CPU % and Memory columns carry a background whose intensity
scales against the highest value currently visible in that column. An unreadable
cell gets **no shading at all** — absence is not a low value.

**Why:** the shading always uses its full range and answers "what is hogging this
right now". Scaling to machine capacity instead leaves the table nearly unshaded
on an idle machine, wasting the feature exactly when you are unsure whether
anything is wrong.

**Cost, accepted:** intensity is not comparable between glances, since the peak
moves.

### 4. Cadence: keep 5 seconds, measure before changing

Ship at the existing `.slow` cadence. The implementation plan measures what a
faster tick actually costs using the existing overhead test before anyone decides
to change it.

**Why:** enumerating ~600 processes is the most expensive thing this app does,
and Vitals ranking high in its own process list would be self-defeating. 5s
matches Activity Monitor. Sampling is subscription-driven, so the cost exists
only while the pane is open.

## Architecture

### Table implementation: SwiftUI `Table`

Chosen over a hand-built `List` and over `NSTableView` via `NSViewRepresentable`.
`Table` is `NSTableView` underneath, so it virtualises ~600 rows, and it gives
column sorting, resizing, reordering, selection and native styling for free —
which serves the project's stated goal of matching Apple's first-party apps. A
hand-built list would reproduce that scaffolding and drift from native; an
AppKit island would not compose with the existing SwiftUI surfaces.

Its one constraint: `KeyPathComparator` cannot express "unknowns last", so that
needs a custom `SortComparator`. This is a small piece of pure logic, which suits
how the rest of this codebase is tested.

### `ProcessesPage` does not use `HardwarePage`

That container is built around a primary value, a chart and a stats block. A
table has none of those. Processes is a genuinely different shape and gets its
own view.

### Store changes

`MetricsStore` gains `processes: ProcessSeriesSample?` — **latest only, no
history**. A 600-sample ring of 600 processes would be 360,000 snapshots for a
table that only shows the present. This mirrors the existing `volumes` decision.

Two existing pieces change:

- `apply(_:for:)`'s `.processes` arm currently returns early with a comment
  saying the pane is M1-B-3. It now stores the sample.
- `expiresWhenStale` returns `false` for `.processes` because no live field
  existed. It becomes `true` — process listings are live data and a stale one
  must not read as current.

### `ProcessRow` view model

A plain struct pairing one snapshot with its CPU usage and carrying formatted
display values. No SwiftUI in it, so formatting, absence and comparison are pure
and directly testable — matching how the existing pages' helpers are tested.

Per-sample work — filtering, and the heat-map column maxima — is computed once
per sample in the view model, never per cell. Six hundred rows across ten columns
recomputing a maximum would be 6,000 array passes per redraw.

## Columns

Ten columns exist. Six are visible by default; the rest are available through
`Table`'s built-in column customisation.

| Column | Default | Source |
|---|---|---|
| Process | visible | `name` |
| CPU % | visible | `cpuUsage[pid]` |
| Memory | visible | `memoryFootprintBytes` |
| PID | visible | `pid` |
| User | visible | `userID` |
| Threads | visible | `threadCount` |
| CPU Time | hidden | `cpuTimeSeconds` |
| Disk Read | hidden | `diskBytesRead` |
| Disk Write | hidden | `diskBytesWritten` |
| Architecture | hidden | `architecture` |

Default sort is **CPU % descending**.

CPU is shown Activity Monitor style: a process saturating four cores reads 400%.
That is what `ProcessCPUTracker` already produces and what macOS users expect.

**The User column shows a name, not a raw uid.** `ProcessSnapshot` carries
`userID: uid_t`, and a column of `0` and `501` is not useful. Resolve via
`getpwuid`, cached per uid for the lifetime of the page since the mapping does
not change while it is open. A uid with no passwd entry — which happens for some
system accounts — renders as the numeric uid rather than an em dash: the value is
known, only its name is missing, and those are different facts.

## Filtering

Case-insensitive substring match on the process name, plus exact PID match when
the query is numeric. Applied before ordering.

Because the heat map scales to visible rows, filtering rescales the shading —
the desired behaviour when narrowing to one app's helper processes.

## States

- **No listing** (`store.processes == nil`): the page states the reason rather
  than showing an empty table, as the CPU page does for its unavailable sensors.
- **Filter matches nothing:** stated distinctly from having no data. Those are
  different facts.

## Absence vocabulary

The app already has two absence forms — `StatRow.displayValue` ("Unavailable")
and `MetricTile.displayValue` (em dash) — and `PageConsistencyTests` exists to
keep them consistent. Table cells use the em-dash form and join that test rather
than introducing a third vocabulary.

## Testing

- **Sort comparator** (most attention): unknowns last in both directions, ties,
  stability.
- **Filter matching:** name substring, case-insensitivity, numeric PID, no match.
- **Heat-map normalisation:** max-relative scaling, unknown yields no shade,
  all-unknown column, single-row table.
- **Absence formatting** for every optional field.
- **Order-holds behaviour:** values change without order changing; a sort change
  does reorder.
- **Render test** building the page from a live store, matching the five that
  exist for the other pages.
- `SidebarSection.isImplemented` gains `.processes`, which makes
  `PageConsistencyTests` fail until the page is real — exactly what that test is
  for.

## Constraints inherited from the project

- **Never fabricate a number.** Unmeasurable is `nil`, rendered as an em dash —
  never `0`, never blank. This design's sorting and heat-map decisions both
  follow from it.
- Swift 6 strict concurrency, language mode 6. Platform floor macOS 26.0. No
  third-party dependencies.
- Build and test output pristine; warning checks require `rm -rf .build` first.
- `swift test --filter` matches type identifiers, not `@Suite` display names.
