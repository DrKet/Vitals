# Processes selection binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Processes table a single-selection binding whose identity is (pid, start time), so a selection survives filtering, is reported as nil once the process exits, and can never transfer to a different process that inherits a recycled pid.

**Architecture:** `ProcessSnapshot` gains a `startTimeSeconds` read from the `kinfo_proc` the sampler already fetches. `ProcessRow` carries it through, a small `ProcessIdentity` pairs pid with start time, and a pure `ProcessTable.validSelection` decides whether a stored identity still matches a current row. `ProcessesPage` holds the identity in `@State` and hands `Table` a computed `Binding<pid_t?>` built over the unfiltered rows, so the guard holds by construction with no reconciliation step.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency), SwiftUI `Table`, Swift Testing (`@Test`/`@Suite`/`#expect`), macOS 26 floor. Sampling via `sysctl(KERN_PROC_ALL)` in `SystemMetrics`.

## Global Constraints

- **Never fabricate a number / never mis-attribute a measurement.** A selection must never report a process that is not the one the user selected. A recycled pid carries a different start time and must fail the identity match.
- **`ProcessRow.id` stays `pid_t`.** Do not make it composite — that ripples into `displayOrder` and `ProcessTable.ordered(keeping:)`, which is out of scope.
- **No float `==`.** This project has been bitten four times by exact float comparison of *computed* values. Start-time identity is compared only through `ProcessIdentity`'s synthesized `Hashable`/`Equatable` (exact struct equality on a kernel value stored without arithmetic — correct here, and not a hand-written float `==`). Do not write `someDouble == otherDouble` anywhere in this work.
- **Single selection**, survives filtering, reports nil once the process leaves the sample. Nothing destructive (no context menu, Quit, inspector, tree) lands here.
- **Swift 6 language mode, strict concurrency, macOS 26.0 floor.**
- **`swift test --filter` matches TYPE identifiers**, not `@Suite` display names (e.g. `ProcessTableTests`, `ProcessTests`).
- **Adding a stored property to a public `SystemMetrics` struct requires a clean build before trusting tests:** `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`. The new field is POD (a `Double`), so it should not trigger the incremental-build SIGSEGV described in AGENTS.md — but the clean build is cheap and mandatory. A nondeterministic signal 11 across unrelated tests is that trap, not a real failure; `rm -rf .build` and retry.
- **Build/test commands:** `cd VitalsCore && swift build` / `swift test` / `swift test --filter <TypeName>`.

---

### Task 1: `ProcessSnapshot.startTimeSeconds` from the sampler

Adds the identity field at the source and threads it through every construction site so the whole suite still compiles and passes. This is the one sampler change the feature needs.

**Files:**
- Modify: `VitalsCore/Sources/SystemMetrics/Processes/ProcessInfo.swift` (the `ProcessSnapshot` struct + its `init`)
- Modify: `VitalsCore/Sources/SystemMetrics/Processes/ProcessSampler.swift` (the `ProcessSnapshot(...)` call in `detail(for:)`)
- Test: `VitalsCore/Tests/SystemMetricsTests/ProcessTests.swift` (new sampler test + update its `snapshot(...)` helper)
- Modify (keep compiling): `VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift`, `ProcessTableTests.swift`, `ProcessRowTests.swift`, `MetricsStoreTests.swift` — every `ProcessSnapshot(...)` construction site.

**Interfaces:**
- Produces: `ProcessSnapshot.startTimeSeconds: Double` (seconds since the Unix epoch, `tv_sec + tv_usec / 1e6`), and the `init` gains a trailing `startTimeSeconds: Double` parameter (no default — every caller states it).

- [ ] **Step 1: Write the failing sampler test**

Add to `VitalsCore/Tests/SystemMetricsTests/ProcessTests.swift`, inside its `@Suite` struct:

```swift
@Test("the sampler reads a real start time for the running process")
func startTimeIsPopulatedForTheCurrentProcess() {
    // getpid() — the test runner itself — is always present in KERN_PROC_ALL
    // and readable (we own it), so its snapshot is a deterministic anchor.
    let mine = ProcessSampler.snapshot().first { $0.pid == getpid() }
    let startTime = try #require(mine).startTimeSeconds
    // A real Unix start time is on the order of 1.7e9; a stubbed or zeroed
    // field fails this, and it must not be in the future.
    #expect(startTime > 1_000_000_000)
    #expect(startTime <= Date().timeIntervalSince1970 + 1)
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `cd VitalsCore && swift test --filter ProcessTests`
Expected: FAIL to compile — `ProcessSnapshot` has no `startTimeSeconds`.

- [ ] **Step 3: Add the field and init parameter, and update every construction site — with the sampler value STUBBED to 0**

In `ProcessInfo.swift`, add the property after `architecture` in the `ProcessSnapshot` struct:

```swift
    public let architecture: ProcessArchitecture

    /// When the process started, in seconds since the Unix epoch
    /// (`p_starttime`). Part of the process's identity: a pid is recycled, so
    /// (pid, startTimeSeconds) is what tells one process from a later one that
    /// inherited its pid. Never displayed — see `ProcessIdentity`.
    public let startTimeSeconds: Double
```

Add the parameter (last) to the `init` signature and body:

```swift
    public init(
        pid: pid_t, parentPID: pid_t, name: String, userID: uid_t,
        memoryFootprintBytes: UInt64?, cpuTimeSeconds: Double?, threadCount: Int?,
        diskBytesRead: UInt64?, diskBytesWritten: UInt64?,
        architecture: ProcessArchitecture,
        startTimeSeconds: Double
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.userID = userID
        self.memoryFootprintBytes = memoryFootprintBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.threadCount = threadCount
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.architecture = architecture
        self.startTimeSeconds = startTimeSeconds
    }
```

In `ProcessSampler.swift`, in the `ProcessSnapshot(...)` return inside `detail(for:)`, add as the last argument — **stubbed to 0 for now** so the next step can show a real red:

```swift
            architecture: architecture(of: process),
            startTimeSeconds: 0  // STUB — real read added in Step 5
```

Now update every test construction site to pass a realistic value (identity is irrelevant in these fixtures, so a constant is fine):

`Tests/SystemMetricsTests/ProcessTests.swift` — the `snapshot(pid:cpuTime:)` helper:

```swift
    private func snapshot(pid: pid_t, cpuTime: Double?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: 1, name: "test", userID: 501,
            memoryFootprintBytes: nil, cpuTimeSeconds: cpuTime, threadCount: nil,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native,
            startTimeSeconds: 1_700_000_000
        )
    }
```

`Tests/VitalsUITests/ProcessesPageTests.swift` — the `snapshot(_:_:cpuTime:)` helper: append `, startTimeSeconds: 1_700_000_000` as the last argument of its `ProcessSnapshot(...)`.

`Tests/VitalsUITests/ProcessTableTests.swift` (the inline `ProcessSnapshot(` around line 23): append `, startTimeSeconds: 1_700_000_000` as the last argument.

`Tests/VitalsUITests/ProcessRowTests.swift` (the two inline `ProcessSnapshot(` sites): append `, startTimeSeconds: 1_700_000_000` to each.

`Tests/VitalsUITests/MetricsStoreTests.swift` (the two inline `ProcessSnapshot(` sites): append `, startTimeSeconds: 1_700_000_000` to each.

- [ ] **Step 4: Run the test to verify it now fails on the assertion (real red)**

Run: `cd VitalsCore && swift test --filter ProcessTests`
Expected: compiles now; `startTimeIsPopulatedForTheCurrentProcess` FAILS at `#expect(startTime > 1_000_000_000)` because the sampler stub returns `0`. This proves the test detects a missing read, not just a missing symbol.

- [ ] **Step 5: Implement the real read**

In `ProcessSampler.swift`, replace the stub line with the real conversion from the `kinfo_proc` already in hand:

```swift
            architecture: architecture(of: process),
            // p_starttime is a timeval (integer seconds + microseconds); this
            // is the process's identity anchor, not a displayed value.
            startTimeSeconds: Double(process.kp_proc.p_starttime.tv_sec)
                + Double(process.kp_proc.p_starttime.tv_usec) / 1_000_000
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd VitalsCore && swift test --filter ProcessTests`
Expected: PASS.

- [ ] **Step 7: Run the whole suite from a clean build**

Run: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` → expect `0`.
Run: `cd VitalsCore && swift test` → expect all pass (every construction site now compiles). If a nondeterministic signal 11 appears, it is the incremental-build trap — `rm -rf .build` and retry once.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/SystemMetrics/Processes/ProcessInfo.swift \
        VitalsCore/Sources/SystemMetrics/Processes/ProcessSampler.swift \
        VitalsCore/Tests/SystemMetricsTests/ProcessTests.swift \
        VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift \
        VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift \
        VitalsCore/Tests/VitalsUITests/ProcessRowTests.swift \
        VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift
git commit -m "feat: read process start time as an identity anchor

pids are recycled, so (pid, startTimeSeconds) is what distinguishes one
process from a later one that inherits its pid. p_starttime is already in the
kinfo_proc the sampler fetches, so this costs nothing extra. Not displayed —
purely for the selection identity a later task builds on."
```

---

### Task 2: `ProcessRow.startTimeSeconds`, `ProcessIdentity`, and `ProcessTable.validSelection`

The pure selection logic, with the weight-bearing recycle test and its mutation check.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessRow.swift` (add `startTimeSeconds`, a computed `identity`, thread it through both inits)
- Modify: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessTable.swift` (add `validSelection`)
- Test: `VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift` (new `validSelection` tests + update its memberwise `row(...)` helper)
- Modify (keep compiling): `VitalsCore/Tests/VitalsUITests/ProcessSortTests.swift` (its memberwise `ProcessRow(...)` site)

**Interfaces:**
- Consumes: `ProcessSnapshot.startTimeSeconds` (Task 1).
- Produces:
  - `ProcessIdentity` — `public struct ProcessIdentity: Hashable, Sendable { public let pid: pid_t; public let startTimeSeconds: Double; public init(pid: pid_t, startTimeSeconds: Double) }`
  - `ProcessRow.startTimeSeconds: Double` and `ProcessRow.identity: ProcessIdentity` (computed)
  - `ProcessTable.validSelection(_ selection: ProcessIdentity?, in rows: [ProcessRow]) -> ProcessIdentity?`

- [ ] **Step 1: Write the failing tests**

Add to `VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift`, inside its `@Suite` struct. These use a small local helper that builds a row with an explicit start time (add it near the existing `row(...)` helper):

```swift
    private func row(_ pid: pid_t, startTime: Double, name: String = "p") -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: "u", cpuFraction: 0, memoryBytes: 0,
            threadCount: nil, cpuTimeSeconds: nil, diskReadBytes: nil,
            diskWrittenBytes: nil, architecture: .native, startTimeSeconds: startTime
        )
    }

    // MARK: validSelection

    @Test("a selection whose row is still present is preserved")
    func presentSelectionIsPreserved() {
        let rows = [row(100, startTime: 1_700_000_000), row(200, startTime: 1_700_000_500)]
        let selection = ProcessIdentity(pid: 100, startTimeSeconds: 1_700_000_000)
        #expect(ProcessTable.validSelection(selection, in: rows) == selection)
    }

    @Test("a recycled pid — same pid, different start time — is NOT preserved")
    func recycledPidIsNotPreserved() {
        // The weight-bearing case. pid 100 is still in the list, but it is a
        // DIFFERENT process (a later start time), so the old selection must
        // not silently transfer to it.
        let rows = [row(100, startTime: 1_700_009_999)]
        let selection = ProcessIdentity(pid: 100, startTimeSeconds: 1_700_000_000)
        #expect(ProcessTable.validSelection(selection, in: rows) == nil)
    }

    @Test("a selection whose pid is gone entirely becomes nil")
    func absentPidBecomesNil() {
        let rows = [row(200, startTime: 1_700_000_500)]
        let selection = ProcessIdentity(pid: 100, startTimeSeconds: 1_700_000_000)
        #expect(ProcessTable.validSelection(selection, in: rows) == nil)
    }

    @Test("a nil selection stays nil")
    func nilSelectionStaysNil() {
        let rows = [row(100, startTime: 1_700_000_000)]
        #expect(ProcessTable.validSelection(nil, in: rows) == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `cd VitalsCore && swift test --filter ProcessTableTests`
Expected: FAIL to compile — `ProcessIdentity`, `ProcessRow.startTimeSeconds`, and `ProcessTable.validSelection` do not exist.

- [ ] **Step 3: Create `ProcessIdentity`**

Create `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift`:

```swift
import Darwin

/// A process's identity across sampling ticks: its pid plus when it started.
///
/// `pid` alone is not an identity — the kernel recycles pids, so a selection
/// held by pid would silently transfer to whatever new process inherits it,
/// and with a context menu on top that is an action aimed at the wrong
/// process. `startTimeSeconds` (from `p_starttime`) distinguishes them.
///
/// `Hashable` is synthesized. Its equality compares `startTimeSeconds`
/// exactly, which is correct and deliberate: the value is a kernel constant
/// stored without any arithmetic, so the same process reports a bit-identical
/// value every tick and a recycled pid reports a genuinely different one.
/// This is identity comparison, not the computed-float comparison the
/// project's float-equality rule warns against.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSeconds: Double

    public init(pid: pid_t, startTimeSeconds: Double) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
    }
}
```

- [ ] **Step 4: Add `startTimeSeconds` and `identity` to `ProcessRow`**

In `ProcessRow.swift`, add the stored property after `architecture`:

```swift
    public let architecture: ProcessArchitecture
    /// The row's process start time, carried from `ProcessSnapshot` so the
    /// selection can build a `ProcessIdentity` (see that type).
    public let startTimeSeconds: Double
```

Add the trailing parameter to the memberwise `init` (signature and body):

```swift
    public init(
        pid: pid_t,
        name: String,
        userName: String,
        cpuFraction: Double?,
        memoryBytes: UInt64?,
        threadCount: Int?,
        cpuTimeSeconds: Double?,
        diskReadBytes: UInt64?,
        diskWrittenBytes: UInt64?,
        architecture: ProcessArchitecture,
        startTimeSeconds: Double
    ) {
        self.pid = pid
        self.name = name
        self.userName = userName
        self.cpuFraction = cpuFraction
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.cpuTimeSeconds = cpuTimeSeconds
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.architecture = architecture
        self.startTimeSeconds = startTimeSeconds
    }
```

Thread it through the `init(snapshot:cpuFraction:userName:)` convenience init — add as the last argument of its `self.init(...)` call:

```swift
            architecture: snapshot.architecture,
            startTimeSeconds: snapshot.startTimeSeconds
```

Add the computed identity (place it just after the stored properties / before the inits, or in the `// MARK: Display` area — anywhere in the type):

```swift
    /// This row's process identity, for the selection binding.
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeSeconds: startTimeSeconds)
    }
```

- [ ] **Step 5: Add `validSelection` to `ProcessTable`**

In `ProcessTable.swift`, add:

```swift
    /// The selection to report, given a stored identity and the current rows.
    ///
    /// Returns the stored `selection` only when a current row has the same
    /// identity — same pid AND same start time. A recycled pid (same pid, new
    /// start time) does not match, so the selection is dropped rather than
    /// transferred to the new process; a pid that has left the sample entirely
    /// likewise drops. Compared through `ProcessIdentity`'s synthesized
    /// equality, never a hand-written float comparison.
    ///
    /// Callers pass the UNFILTERED rows: a selection hidden by the filter is
    /// still present in the sample and must survive, reappearing when the
    /// filter clears.
    public static func validSelection(
        _ selection: ProcessIdentity?, in rows: [ProcessRow]
    ) -> ProcessIdentity? {
        guard let selection else { return nil }
        return rows.contains { $0.identity == selection } ? selection : nil
    }
```

- [ ] **Step 6: Update the memberwise `ProcessRow(...)` sites that now lack the argument**

`ProcessTableTests.swift` — the pre-existing `row(_:name:cpu:memory:)` helper: append `, startTimeSeconds: 1_700_000_000` to its `ProcessRow(...)`.

`ProcessSortTests.swift` — this file has a single `row(...)` factory whose `ProcessRow(...)` ends `... architecture: architecture)`. Append `, startTimeSeconds: 1_700_000_000` as the last argument of that one constructor; every test in the file goes through it, so no other edit is needed there.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd VitalsCore && swift test --filter ProcessTableTests`
Expected: PASS (new `validSelection` tests and the pre-existing ones).

- [ ] **Step 8: Mutation-check the recycle guard**

Temporarily weaken `validSelection` to match pid only:

```swift
        return rows.contains { $0.pid == selection.pid } ? selection : nil
```

Run: `cd VitalsCore && swift test --filter ProcessTableTests`
Expected: `recycledPidIsNotPreserved` FAILS (pid-only wrongly preserves the selection), the others still pass. This proves that test is what distinguishes this design from the pid-only version. **Restore** the `$0.identity == selection` version and re-run to confirm green.

- [ ] **Step 9: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift \
        VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessRow.swift \
        VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessTable.swift \
        VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift \
        VitalsCore/Tests/VitalsUITests/ProcessSortTests.swift
git commit -m "feat: process selection identity and validSelection

ProcessIdentity pairs pid with start time; ProcessRow carries the start time
through and exposes an identity; ProcessTable.validSelection returns a stored
identity only when a current row still matches both fields, so a recycled pid
drops the selection rather than transferring it. Pure and directly tested,
including a mutation check that the recycle case fails under pid-only matching."
```

---

### Task 3: Wire the selection into `ProcessesPage`

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessesPage.swift`
- Test: existing `VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift` must stay green (its render tests already build the page from a live store).

**Interfaces:**
- Consumes: `ProcessTable.validSelection(_:in:)`, `ProcessRow.identity`, `ProcessIdentity` (Task 2); the page's existing `all`/`rows` locals in `body` (the unfiltered and filtered-ordered rows).
- Produces: no new public API.

- [ ] **Step 1: Add the selection state**

In `ProcessesPage.swift`, add alongside the other `@State` (near `sortOrder`, `columns`, `displayOrder`):

```swift
    /// The selected process, held by identity (pid + start time) so a recycled
    /// pid never transfers the selection — see `ProcessTable.validSelection`.
    /// The `Table` below is driven by a computed `Binding<pid_t?>`, not this
    /// directly, so the guard is applied on every read.
    @State private var selected: ProcessIdentity?
```

- [ ] **Step 2: Build the guarded binding and pass it to `Table`**

`body` already computes `let all = currentRows()` (unfiltered) and `let rows = ProcessTable.ordered(filtered, keeping: displayOrder)` (displayed). Add a binding built over `all`, immediately before the `return VStack(...)` (so it can close over `all`):

```swift
        // Reported selection is guarded on every read: the getter returns a
        // pid only when a current row matches the stored identity, and the
        // setter records the full identity of the clicked row. Built over
        // `all` (unfiltered) so a selection the filter hides survives and
        // reappears when the filter clears; `Table` renders `rows`, and a pid
        // absent from the visible set simply shows no selection meanwhile.
        let selection = Binding<pid_t?>(
            get: { ProcessTable.validSelection(selected, in: all)?.pid },
            set: { newValue in
                selected = newValue.flatMap { pid in all.first { $0.pid == pid }?.identity }
            }
        )
```

Change the `Table(...)` construction to take the selection binding:

```swift
        Table(rows, selection: selection, sortOrder: $sortOrder, columnCustomization: $columns) {
```

(Everything inside the `Table { ... }` column builder is unchanged.)

**On the spec's "survives filtering" and "reports nil on exit" test cases:** these are not separate tests here — they are the pure `validSelection` cases from Task 2 (`presentSelectionIsPreserved` and `absentPidBecomesNil`) applied to the *unfiltered* rows. Filter-survival holds because this binding validates against `all`, which contains the selection whether or not the filter hides it; exit-clearing holds because a process that has left the sample is absent from `all` and so validates to nil. The load-bearing choice a reviewer should confirm is that the getter passes `all`, not `rows` — that single decision is what makes both behaviors true, and it is not separately unit-testable through a SwiftUI `Binding`.

- [ ] **Step 3: Verify the page still builds and its render tests pass**

Run: `cd VitalsCore && swift test --filter ProcessesPageTests`
Expected: PASS. The existing render tests construct `ProcessesPage(store:)` and render it; adding the selection binding must not change what they assert (they cover cold-start captions, default ordering, heat-map saturation — none touch selection). If any fail, do not weaken them — a failure here means the binding changed layout or crashed construction; investigate that.

- [ ] **Step 4: Run the whole suite from a clean build**

Run: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` → expect `0`.
Run: `cd VitalsCore && swift test` → expect all pass. (The load-sensitive `MetricsStoreTests` `waitUntil` timeouts are the known flakiness, not a regression from this change — re-run once if they appear.)

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessesPage.swift
git commit -m "feat: single-selection binding on the Processes table

The table's selection is held by identity and read through a guarded
Binding<pid_t?> built over the unfiltered rows: the getter reports a pid only
while a current row still matches the stored identity, so a selection survives
filtering and is dropped the moment its process leaves the sample or a
recycled pid takes its place. Prerequisite for the context menu, inspector and
tree view; none of those land here."
```

---

## Notes for the implementer

- **`ProcessRow.id` stays `pid_t`** (its `var id: pid_t { pid }`). The selection binding is `Binding<pid_t?>` because `Table` selects by `id`. Do not change `id`.
- **The binding lives in `body`, not as `@State`.** It must close over the `all` local computed that render, so it reflects the latest sample every evaluation. Do not hoist it out.
- **No `onChange`, no reconciliation.** The guard is applied in the getter on every read; there is deliberately nothing to run when a sample arrives. `body` already documents its sensitivity to redundant per-render passes — do not add work there.
- **Start-time fixtures use a constant** (`1_700_000_000`) wherever identity is irrelevant. The only tests that need *distinct* start times are the `validSelection` cases in Task 2, which set them explicitly.
- **Out of scope:** context menu, Quit/Force Quit/Suspend/Resume/renice, inspector sheet, process tree, Apps/Background/System grouping.
