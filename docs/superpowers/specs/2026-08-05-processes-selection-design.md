# Processes table — selection

The Processes table has no `selection:` binding. Three deferred slices of spec
§4.7 need one before they can start: the context menu, the inspector sheet and
the tree view. This adds it, and nothing else.

## Scope

Selection only. Nothing destructive lands here — no context menu, no Quit or
Force Quit, no inspector, no tree. Those each raise their own design questions,
and Force Quit in particular needs a safety design that does not belong in the
increment that merely makes a row selectable.

One sampler change is in scope, and only because selection cannot be made
correct without it: see Identity below.

## Decisions

**Single selection.** One row at a time, as Activity Monitor does. The
inspector then has exactly one subject, and a later Force Quit acts on one
clearly named process rather than a bulk irreversible action.

**Selection survives filtering.** Typing in the filter field is a view change,
not a decision to deselect. A selection hidden by the filter is still selected
when the filter is cleared.

**Selection clears when the process exits.** This is a correctness
requirement, not a nicety — see below.

## Identity, and why the sampler changes

`ProcessRow.id` is the pid, and **pids are recycled**. A selection held by pid
alone silently transfers to whatever new process inherits that pid. With a
context menu on top, that is a Force Quit aimed at the wrong process. It is the
same class of error as attributing a reading to the wrong hardware, which the
project's one rule already forbids.

Clearing on exit does not by itself close this. If a process exits and another
takes its pid between two samples, the pid never appears absent and there is no
exit to react to.

So identity must be more than the pid. `ProcessSnapshot` gains:

```swift
public let startTimeSeconds: Double   // p_starttime, tv_sec + tv_usec / 1e6
```

`p_starttime` is already inside the `kinfo_proc` that `ProcessSampler` fetches
via `KERN_PROC_ALL`, so obtaining it costs nothing extra. Verified populated on
this machine at microsecond resolution:

```
pid 98438   start 1785981211.614366   zsh
pid 98417   start 1785981194.739085   mdworker_shared
```

Two alternatives were considered and rejected. **pid only** leaves exactly the
hole described above. **(pid, name)** catches a recycled pid that belongs to a
differently-named process, but misses a helper that crashes and respawns under
the same name — which is the case most likely to occur in practice.

`ProcessRow.id` deliberately stays `pid_t`. Making it composite would ripple
into `displayOrder` and `ProcessTable.ordered(keeping:)`, which is blast radius
this feature does not need.

## Architecture

`ProcessIdentity` is a `Hashable` pair of pid and start time. The page holds
`@State private var selected: ProcessIdentity?`, and `Table` is given a
`Binding<pid_t?>` computed in `body` over the unfiltered rows:

- **getter** — returns `selected.pid` only when some row matches *both* the pid
  and the start time; `nil` otherwise.
- **setter** — looks the incoming pid up in the unfiltered rows and stores that
  row's full identity. A `nil` write (clicking empty space) stores `nil`.

**The guard holds by construction.** A recycled pid carries a different start
time, fails the match, and the selection is simply not reported — there is no
reconciliation step to run at the wrong moment, and no `onChange` to add to a
`body` that already documents its sensitivity to redundant per-render passes.

That a stale identity lingers in `@State` is unobservable. If the *identical*
process reappears after a sampling gap, the selection correctly returns; that
is the same process, not a different one wearing its pid.

Filtering needs no code. The getter tests against the unfiltered rows while
`Table` renders the filtered ones, so a hidden selection stays stored and
reappears when the filter clears.

The decision itself is a pure function on `ProcessTable`, matching that file's
stated convention that every decision about absence and ordering lives there
rather than in the view:

```swift
public static func validSelection(
    _ selection: ProcessIdentity?, in rows: [ProcessRow]
) -> ProcessIdentity?
```

## Testing

The test that carries the weight is **pid present, start time different →
nil**. That is the recycle case, and it is the one assertion that distinguishes
this design from the pid-only version it replaces. It will be mutation-checked
by weakening identity to pid alone and confirming it goes red.

Also covered:

- a selection whose row is present is preserved
- a selection whose pid is absent entirely becomes `nil`
- a `nil` selection stays `nil`
- selection survives a filter change that hides the row, and returns when the
  filter clears
- the table reports no selection once the process leaves the sample

To be unambiguous about that last one: what is asserted is the *reported*
selection — what `Table` is given and what a context menu would act on. The
stored `@State` is not asserted either way, because it is not observable. An
implementation that clears the state and one that leaves it both satisfy this
spec; neither can report a stale process.

Every test is watched failing before the implementation exists. Per the
project's standing lesson, the briefs above are drafts: an assertion that
passes the moment it is written has proved nothing and must be interrogated.

`ProcessSnapshot` gains a stored property, so fixtures that construct it need
updating, and the suite must be run after `rm -rf .build` — see AGENTS.md on
incremental builds and signal 11. The new field is POD, so it should not
trigger that crash, but the clean build is cheap and the rule is absolute.

## Out of scope

Context menu, Quit / Force Quit / Suspend / Resume / renice, the inspector
sheet, the process tree, and Apps/Background/System grouping. Selection is the
prerequisite for all of them; none of them lands here.
