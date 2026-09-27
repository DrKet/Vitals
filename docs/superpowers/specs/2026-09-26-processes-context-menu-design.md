# Processes table — context menu

The Processes table gained a single-selection binding in the previous slice,
built on `ProcessIdentity` (pid + start time) precisely so that an action
could never land on a recycled pid. This slice puts the first actions on top
of it: a right-click menu with Copy PID, Copy Name, Reveal in Finder, Quit and
Force Quit.

## Scope

In: the context menu, the five items above, a confirmation alert for Quit and
Force Quit, and a new `ProcessControl` target that performs the two
signalling actions.

Out — each raises its own design question and gets its own slice:

- **Suspend / Resume.** A suspended process needs to *look* suspended, and the
  table has no status column to show it.
- **renice.** Raising priority needs root.
- **Sample Process, Spindump.** Spindump needs root; both produce reports that
  need somewhere to go.
- **Inspect.** Needs the inspector sheet.
- **Multi-select actions.** Selection is single.
- **Acting on other users' or root's processes.** Needs the privileged helper
  (spec §4.7, M3).

## Decisions

**Always confirm, Activity Monitor style.** Both Quit… and Force Quit… open
the same alert — titled *Are you sure you want to quit this process?*, with
the process's name and pid in the message — and Force Quit, Cancel and Quit
buttons. (The title is fixed, as Activity Monitor's is; a SwiftUI alert's
title cannot depend on the pending action without inventing a fallback
string for when there is none.) The item the user chose is the default button, so
Return confirms what they asked for. One misclick on a neighbouring row must
not kill a process.

**Quit is polite; Force Quit is not.** Quit on a GUI app goes through
`NSRunningApplication.terminate()` — the same request ⌘Q sends, so the app can
stop to ask about unsaved work. Quit on anything else is `SIGTERM`. Force Quit
is `SIGKILL` for everything.

**Unavailable actions are shown disabled, with the reason.** Hiding Quit on a
root process would leave the user wondering where it went. The menu keeps the
items, greys them out, and adds a disabled line giving the specific reason —
see the rules table under Architecture. The "needs administrator access"
reason goes away when the privileged helper exists; the system-critical one
never does.

**Vitals does not quit itself from its own table.** Quit and Force Quit are
disabled on Vitals' own row; the app menu is where quitting Vitals belongs.

**No optimistic removal.** After a successful action the row is not deleted
from the table. The next sample removes it — or shows it still running, if the
app stopped to ask about saving. Removing it early would report an exit the
machine never reported, the same class of error as a fabricated reading.

## Identity at action time

The menu acts on a `ProcessIdentity`, never a bare pid. The right-clicked pid
is resolved to an identity through the **unfiltered** current rows, exactly as
`ProcessTable.validSelection` does, so a row hidden by the filter still
resolves. A pid with no current row resolves to nothing, and the menu shows a
single disabled "Process has exited" item.

The identity captured at right-click is what the confirmation alert holds.
The alert can stay open indefinitely, so identity is checked **again** inside
`ProcessControl.perform`, immediately before signalling:

1. Read the pid's `kinfo_proc` afresh with `sysctl` (`KERN_PROC_PID`).
2. No such process → `.exited`.
3. The process's start time differs from the identity's → `.exited`. The pid
   now belongs to a different process; signalling it would be an action aimed
   at the wrong process.
4. Otherwise send the action.

**The start-time conversion is extracted and shared.** Identity equality
compares `startTimeSeconds` exactly (see `ProcessIdentity`'s doc comment),
which is only sound if both sides run the identical arithmetic on the
identical kernel value. The sampler's `tv_sec + tv_usec / 1_000_000` becomes
one `SystemMetrics` function that both the sampler and the re-check call. Two
hand-written copies could drift and make a live process fail its own identity
check — or, worse, make two different processes pass.

**A residual race remains and is stated, not hidden.** Between step 3 and the
`kill()` there is a window of microseconds in which the process could exit and
its pid be reused. macOS offers no stable process handle to an unprivileged,
unentitled app (no pidfd equivalent; `task_for_pid` needs entitlements), so
this cannot be closed completely. The re-check shrinks the window from
"however long the alert was open" to that.

## Architecture

### `ProcessIdentity` moves to `SystemMetrics`

`ProcessControl` sits below `VitalsUI` and cannot import it. `ProcessIdentity`
describes a sampled process, `SystemMetrics` already owns the snapshot that
carries its fields, and `VitalsUI` already imports `SystemMetrics`. The type
moves unchanged; its call sites in `VitalsUI` keep compiling through the
existing import.

### New target: `ProcessControl`

Depends on `SystemMetrics` only. `VitalsUI` and `VitalsApp` depend on it.
Kept out of `SystemMetrics`, which is documented as sampling with no side
effects, and out of `MetricsEngine`, which schedules samplers and has no
business sending signals. Data still flows one way through the sampling
stack; control is a separate, parallel path.

```swift
public enum ProcessAction: Sendable { case quit, forceQuit }

public enum ProcessControlError: Error, Equatable {
    /// Gone, or its pid now belongs to a different process.
    case exited
    /// EPERM — not ours to signal.
    case notPermitted
    /// `NSRunningApplication.terminate()` returned false: the quit request
    /// could not be sent. Its own case rather than `.failed(errno: 0)`, since
    /// there is no errno and `0` would be an invented one.
    case quitRequestNotSent
    case failed(errno: Int32)
}

public enum ProcessControl {
    public static func perform(_ action: ProcessAction, on identity: ProcessIdentity) throws
}
```

Error mapping: `ESRCH` → `.exited`; `EPERM` → `.notPermitted`; any other
`errno` → `.failed(errno:)`.

### `VitalsUI`: the menu model

A pure function decides what the menu shows, so every rule has a direct test
and the view only renders it:

```swift
enum QuitUnavailableReason: Equatable {
    case needsAdministrator   // root's or another user's process
    case systemCritical       // pid 0 or 1: not quittable by anyone
    case isVitals             // quit Vitals from its own app menu
}

struct ProcessMenuState: Equatable {
    /// `nil` means Quit… and Force Quit… are enabled. Otherwise both are
    /// disabled and the menu shows a disabled line with the reason.
    var quitUnavailable: QuitUnavailableReason?
    var canReveal: Bool
}

enum ProcessMenu {
    static func state(
        for row: ProcessRow,
        currentUserID: uid_t,
        ownPID: pid_t,
        executablePath: String?
    ) -> ProcessMenuState
}
```

Rules, checked in this order (first match wins):

| Condition | `quitUnavailable` | Disabled line shown |
|---|---|---|
| pid 0 (`kernel_task`) or pid 1 (`launchd`) | `.systemCritical` | "System process — can't be quit" |
| Vitals' own pid | `.isVitals` | "Quit Vitals from its app menu" |
| Owned by root or another user | `.needsAdministrator` | "Quitting this process needs administrator access" |
| Owned by current user | `nil` | — |

pids 0 and 1 are checked before ownership because administrator access would
not help: even root cannot quit `kernel_task`, and killing `launchd` panics
the machine. Telling the user it "needs administrator access" would be false.

`canReveal` is simply `executablePath != nil`. The path is looked up with
`proc_pidpath` when the menu opens, for the one clicked process — never
sampled per tick for every row.

This needs `ProcessRow` to carry `userID: uid_t`. Today it holds only the
resolved `userName`, which cannot tell "you" from "a different user with the
same display name". `ProcessRow`'s public memberwise `init` gains the
parameter, so test fixtures that build rows directly change with it.
`uid_t` is not refcounted, so by `AGENTS.md`'s table the stale-build SIGSEGV
should not trigger — but the plan still does `rm -rf .build` after the change
rather than rely on that.

### `ProcessesPage`: wiring

- `.contextMenu(forSelectionType: pid_t.self)` on the table, resolving the
  pid to a row through the unfiltered rows.
- Copy PID / Copy Name write to `NSPasteboard.general`.
- Reveal in Finder calls `NSWorkspace.activateFileViewerSelecting`, with the
  running app's `bundleURL` when the pid is a GUI app (revealing
  `Safari.app`, not `Safari.app/Contents/MacOS/Safari`), else the executable
  path.
- Quit… / Force Quit… set a pending-action state holding the identity, the
  name and the chosen action; the alert reads from it.
- Confirming calls `ProcessControl.perform`. A thrown error sets an error
  state shown as a second alert, e.g. *"Safari" couldn't be quit because it
  has already exited.* / *…because you don't have permission.*

## Testing

Every test is watched failing before the implementation exists. `--filter`
uses type identifiers (`ProcessControlTests`), never suite display names, and a
"0 tests passed" run counts as a failure to run.

**`ProcessControlTests` — against real processes.** Each test spawns its own
`/bin/sleep 60` child via `Foundation.Process`, reads its identity with the
sampler, and cleans up after itself. No test ever signals a process it did not
start.

- Quit ends the child; its termination reason is `SIGTERM`.
- Force Quit ends the child; its termination reason is `SIGKILL`.
- **The safety test:** the child's real pid with a start time off by one
  second throws `.exited`, and the child is **still running** afterwards.
- A child that has already exited and been reaped throws `.exited`.
- pid 1 throws `.notPermitted` (launchd is root's).

**Shared start-time conversion.** For a live child, the identity built from
the sampler's snapshot equals the identity `ProcessControl`'s re-read
produces. This is the test that catches the two sides drifting.

**`ProcessMenuTests` — the pure rules.** One case per row of the table above,
plus the precedence cases that matter: pid 1 is root-owned yet reports
`.systemCritical`, not `.needsAdministrator`; and `canReveal` with and without
a path.

**Not render-tested.** A SwiftUI context menu does not render in the
off-screen harness. Instead, a **live check before merge**, as the selection
slice had:

1. Start `sleep 600` in Terminal; filter the table to it; right-click → Copy
   PID and paste; Reveal in Finder shows `/bin/sleep`.
2. Quit… → alert names `sleep` with Quit as default → confirm → the row
   disappears on the next sample.
3. Repeat with Force Quit.
4. Right-click a root process: Quit/Force Quit disabled, the administrator
   line present.
5. Open the Quit alert on a `sleep`, kill it from Terminal, then confirm:
   the "already exited" error appears.

No real application is quit at any point in testing.

## Out of scope

Suspend, Resume, renice, Sample Process, Spindump, Inspect, multi-select
actions, and acting on processes that belong to root or another user. The
`ProcessControl` target is where the signal-based ones will land.

## Addendum (during implementation)

- `ProcessControlError.notSignallable` — pid ≤ 0 is refused before anything
  else, because `kill(2)` reads pid 0 as the caller's own process group and a
  negative pid as a whole process group, and `KERN_PROC_PID` with pid 0
  returns `kernel_task` — so the identity check alone would not catch it.
- Zombies are skipped by the sampler, re-checked in one pass after the
  rusage/taskinfo reads rather than per process, and given no identity: a
  zombie's rusage reads back zeroed, so it has nothing real to report and
  nothing safe to signal.
- `VitalsApp` gets `ProcessControl` transitively, through `VitalsUI`, not as
  a direct package dependency.
