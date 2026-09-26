# Processes context menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A right-click menu on the Processes table with Copy PID, Copy Name, Reveal in Finder, Quit… and Force Quit…, where the two signalling actions are confirmed and can never land on a process other than the one the user right-clicked.

**Architecture:** `ProcessIdentity` moves down into `SystemMetrics`, which also gains a single-pid identity re-read that shares the sampler's exact start-time conversion. A new `ProcessControl` target (depends on `SystemMetrics` only) re-checks identity immediately before sending `SIGTERM`/`SIGKILL` or a polite `NSRunningApplication.terminate()`. `VitalsUI` gets a pure `ProcessMenu` model (what is enabled, and every user-facing string) and `ProcessesPage` wires it to `.contextMenu(forSelectionType:)` plus two alerts.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency, typed throws), SwiftUI `Table` / `.contextMenu(forSelectionType:)` / `.alert`, AppKit (`NSRunningApplication`, `NSWorkspace`, `NSPasteboard`), Darwin (`sysctl`, `kill`, `proc_pidpath`), Swift Testing. macOS 26 floor.

**Spec:** `docs/superpowers/specs/2026-09-26-processes-context-menu-design.md`

## Global Constraints

- **Never act on the wrong process.** Every action takes a `ProcessIdentity` (pid + start time), never a bare pid. `ProcessControl.perform` re-reads identity from the kernel immediately before signalling and throws `.exited` on any mismatch. This is the same class of error as attributing a reading to the wrong hardware.
- **Never fabricate.** No invented errno (`quitRequestNotSent` exists for that reason). No optimistic row removal after an action — the next sample decides.
- **Tests never signal a process they did not spawn.** Every `ProcessControl` test spawns its own `/bin/sleep`. The one test that targets pid 1 is disabled when running as root.
- **No float `==` on computed values.** Identity is compared only via `ProcessIdentity`'s synthesized `Equatable`, which is sound because both sides run the one shared start-time conversion.
- **Swift 6 language mode, strict concurrency, macOS 26.0 floor.** No third-party dependencies.
- **`swift test --filter` matches TYPE identifiers** (`ProcessControlTests`, `ProcessMenuTests`, `ProcessTests`), never `@Suite` display names. A run reporting "0 tests" is a failure to run, not a pass.
- **Clean builds after struct changes.** After changing a public struct's stored properties: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`. A nondeterministic signal 11 across unrelated tests is the stale-build trap in AGENTS.md, not a bug.
- **Known load flake.** Under machine load, `waitUntil` timeouts at `MetricsStoreTests.swift:618` (and occasionally `ProcessTests.swift:85`) fail intermittently on `main` too. If the full suite fails ONLY there, rerun; do not "fix" them in this branch.
- **Build/test:** `cd VitalsCore && swift build` / `swift test` / `swift test --filter <TypeName>`.

## File map

| File | Change | Responsibility |
|---|---|---|
| `Sources/SystemMetrics/Processes/ProcessIdentity.swift` | Create (moved) | pid + start time identity type |
| `Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift` | Delete | — |
| `Sources/SystemMetrics/Processes/ProcessSampler.swift` | Modify | shared start-time conversion, `identity(of:)`, `executablePath(of:)` |
| `Sources/SystemMetrics/Processes/ProcessInfo.swift` | Modify | `ProcessSnapshot.identity` |
| `Sources/ProcessControl/ProcessControl.swift` | Create | identity-checked Quit / Force Quit |
| `Package.swift` | Modify | new target, product, test target, `VitalsUI` dependency |
| `Sources/VitalsUI/Pages/Processes/ProcessRow.swift` | Modify | carry `userID` |
| `Sources/VitalsUI/Pages/Processes/ProcessMenu.swift` | Create | pure menu model + every menu/alert string |
| `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift` | Modify | context menu, confirmation + failure alerts |
| `Tests/SystemMetricsTests/ProcessTests.swift` | Modify | identity re-read + path tests |
| `Tests/ProcessControlTests/ProcessControlTests.swift` | Create | real-process signalling tests |
| `Tests/VitalsUITests/ProcessMenuTests.swift` | Create | menu rules + strings |
| `Tests/VitalsUITests/ProcessTableTests.swift`, `ProcessSortTests.swift` | Modify | row fixtures gain `userID` |
| `AGENTS.md` | Modify | current state, layout, stale notes |

All paths below are relative to `VitalsCore/` unless they start with `docs/` or `AGENTS.md`.

---

### Task 1: Identity in `SystemMetrics` — move the type, share the conversion, add single-pid reads

**Files:**
- Create: `Sources/SystemMetrics/Processes/ProcessIdentity.swift`
- Delete: `Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift`
- Modify: `Sources/SystemMetrics/Processes/ProcessSampler.swift`
- Modify: `Sources/SystemMetrics/Processes/ProcessInfo.swift`
- Modify: `Sources/VitalsUI/Pages/Processes/ProcessTable.swift` (add `import SystemMetrics`)
- Modify: `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift` (add `import SystemMetrics`)
- Test: `Tests/SystemMetricsTests/ProcessTests.swift`

**Interfaces:**
- Produces (all `public`, in module `SystemMetrics`):
  - `struct ProcessIdentity: Hashable, Sendable { let pid: pid_t; let startTimeSeconds: Double; init(pid:startTimeSeconds:) }` — unchanged shape, new module.
  - `extension ProcessSnapshot { var identity: ProcessIdentity }`
  - `ProcessSampler.identity(of pid: pid_t) -> ProcessIdentity?` — `nil` when no such process.
  - `ProcessSampler.executablePath(of pid: pid_t) -> String?` — `nil` when unreadable.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SystemMetricsTests/ProcessTests.swift`, inside `struct ProcessTests`:

```swift
    // MARK: Single-process reads

    /// A throwaway child this test owns outright. Every test that needs a live
    /// process spawns its own — nothing here ever touches a process it did
    /// not start.
    private static func spawnSleep() throws -> Foundation.Process {
        let child = Foundation.Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        return child
    }

    private static func reap(_ child: Foundation.Process) {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }

    /// The test that catches the two start-time conversions drifting apart.
    /// `ProcessIdentity` compares start times exactly, which is only sound if
    /// the sampler and the single-pid re-read run identical arithmetic.
    @Test("a single-pid identity read equals the identity the full sampler reports")
    func singlePidIdentityMatchesSampler() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        let sampled = try #require(
            ProcessSampler.snapshot().first { $0.pid == child.processIdentifier }
        )
        #expect(ProcessSampler.identity(of: child.processIdentifier) == sampled.identity)
    }

    @Test("there is no identity for a process that has exited")
    func noIdentityAfterExit() throws {
        let child = try Self.spawnSleep()
        let pid = child.processIdentifier
        Self.reap(child)

        #expect(ProcessSampler.identity(of: pid) == nil)
    }

    @Test("the executable path of a spawned sleep is /bin/sleep")
    func executablePathOfChild() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        #expect(ProcessSampler.executablePath(of: child.processIdentifier) == "/bin/sleep")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ProcessTests`
Expected: build FAILS — `ProcessSnapshot` has no member `identity`, `ProcessSampler` has no member `identity(of:)` / `executablePath(of:)`.

- [ ] **Step 3: Move `ProcessIdentity` into `SystemMetrics`**

Delete `Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift`:

```bash
git rm VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessIdentity.swift
```

Create `Sources/SystemMetrics/Processes/ProcessIdentity.swift` with the same type, doc comment updated for its new home:

```swift
import Darwin

/// A process's identity across sampling ticks: its pid plus when it started.
///
/// `pid` alone is not an identity — the kernel recycles pids, so anything held
/// by pid would silently transfer to whatever new process inherits it. With a
/// Quit or Force Quit on top, that is an action aimed at the wrong process.
/// `startTimeSeconds` (from `p_starttime`) distinguishes them.
///
/// Lives in `SystemMetrics` so both the UI's selection and `ProcessControl`'s
/// pre-signal re-check can use it; every value of it is produced by
/// `ProcessSampler.startTimeSeconds(of:)`, so the two sides always agree.
///
/// `Hashable` is synthesized. Its equality compares `startTimeSeconds`
/// exactly, which is correct and deliberate: the value is a kernel constant
/// converted by one shared function, so the same process reports a
/// bit-identical value every read and a recycled pid reports a genuinely
/// different one. This is identity comparison, not the computed-float
/// comparison the project's float-equality rule warns against.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSeconds: Double

    public init(pid: pid_t, startTimeSeconds: Double) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
    }
}
```

- [ ] **Step 4: Add `ProcessSnapshot.identity`**

Append to `Sources/SystemMetrics/Processes/ProcessInfo.swift`, directly after the closing brace of `struct ProcessSnapshot`:

```swift
extension ProcessSnapshot {
    /// This process's identity — see `ProcessIdentity`.
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeSeconds: startTimeSeconds)
    }
}
```

- [ ] **Step 5: Share the start-time conversion and add the single-pid reads**

In `Sources/SystemMetrics/Processes/ProcessSampler.swift`, replace the `startTimeSeconds:` argument at the end of the `ProcessSnapshot(...)` call in `detail(for:)`:

```swift
            architecture: architecture(of: process),
            startTimeSeconds: startTimeSeconds(of: process)
        )
```

(The two-line comment about `p_starttime` that preceded the old argument moves onto the new function below.)

Then add, inside `enum ProcessSampler`, after `snapshot()`:

```swift
    /// The identity of one process, read afresh from the kernel — `nil` when
    /// no process has that pid.
    ///
    /// This is what `ProcessControl` checks immediately before signalling, so
    /// it must produce exactly what `snapshot()` produced for the same
    /// process. Both go through `startTimeSeconds(of:)`; never convert
    /// `p_starttime` anywhere else.
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let process = kernelProcess(pid: pid) else { return nil }
        return ProcessIdentity(pid: pid, startTimeSeconds: startTimeSeconds(of: process))
    }

    /// The executable's path (`proc_pidpath`), or `nil` when it cannot be
    /// read — the process exited, or it belongs to another user and the
    /// kernel declines to say.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// One process via `KERN_PROC_PID`. For a pid with no process the call
    /// still succeeds but reports a zero length, which is what the length
    /// check catches.
    private static func kernelProcess(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &process, &length, nil, 0) == 0,
              length == MemoryLayout<kinfo_proc>.stride else { return nil }
        return process
    }

    /// `p_starttime` (a timeval: integer seconds + microseconds) as seconds
    /// since the epoch. The process's identity anchor, not a displayed value.
    ///
    /// The ONE place this conversion is written. `ProcessIdentity` compares
    /// the result exactly, so a second hand-written copy that rounded even
    /// slightly differently could make a live process fail its own identity
    /// check.
    static func startTimeSeconds(of process: kinfo_proc) -> Double {
        Double(process.kp_proc.p_starttime.tv_sec)
            + Double(process.kp_proc.p_starttime.tv_usec) / 1_000_000
    }
```

- [ ] **Step 6: Keep `VitalsUI` compiling**

Add `import SystemMetrics` to the import block of both:
- `Sources/VitalsUI/Pages/Processes/ProcessTable.swift` (after `import MetricsEngine`)
- `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift` (after `import MetricsEngine`)

`ProcessRow.swift` already imports `SystemMetrics`. `Tests/VitalsUITests/ProcessTableTests.swift` already imports `SystemMetrics`, so its `ProcessIdentity(...)` uses keep working.

- [ ] **Step 7: Run to verify they pass**

Run: `swift test --filter ProcessTests`
Expected: PASS, including the three new tests. Then `swift test --filter ProcessTableTests` — PASS (the selection tests now use the moved type).

- [ ] **Step 8: Prove the drift test can go red**

Temporarily change the divisor in `startTimeSeconds(of:)` from `1_000_000` to `1_000_001` **only inside `identity(of:)`** by inlining a copy there, e.g. replace its return with:

```swift
        return ProcessIdentity(pid: pid, startTimeSeconds: Double(process.kp_proc.p_starttime.tv_sec)
            + Double(process.kp_proc.p_starttime.tv_usec) / 1_000_001)
```

Run: `swift test --filter ProcessTests`
Expected: `singlePidIdentityMatchesSampler` FAILS (unless the child happened to start on an exact second boundary — if it passes, rerun once). Revert to the shared call, rerun, PASS.

- [ ] **Step 9: Clean build, full suite, commit**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected: `0`.

Run: `swift test` — expected all pass (see the load-flake note in Global Constraints).

```bash
git add -A VitalsCore
git commit -m "feat: process identity in SystemMetrics with a shared single-pid re-read

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ProcessControl` target — identity-checked Quit and Force Quit

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ProcessControl/ProcessControl.swift`
- Test: `Tests/ProcessControlTests/ProcessControlTests.swift`

**Interfaces:**
- Consumes: `ProcessIdentity`, `ProcessSampler.identity(of:)` (Task 1).
- Produces (module `ProcessControl`):
  - `public enum ProcessAction: Sendable, Equatable { case quit, forceQuit }`
  - `public enum ProcessControlError: Error, Equatable, Sendable { case exited, notPermitted, notSignallable, quitRequestNotSent, failed(errno: Int32) }` — `notSignallable` (added in review) is pid 0, which `kill(2)` would read as "the caller's own process group"; `perform` refuses it before anything else.
  - `@MainActor public enum ProcessControl { static func perform(_ action: ProcessAction, on identity: ProcessIdentity) throws(ProcessControlError) }`

- [ ] **Step 1: Register the target and test target**

In `Package.swift`:

Add to `products`, after the `MetricsEngine` library line:
```swift
        .library(name: "ProcessControl", targets: ["ProcessControl"]),
```

Add to `targets`, after the `MetricsEngine` target:
```swift
        .target(
            name: "ProcessControl",
            dependencies: ["SystemMetrics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

Change the `VitalsUI` target's dependencies to:
```swift
            dependencies: ["SystemMetrics", "MetricsEngine", "ProcessControl"],
```

Add a test target after `MetricsEngineTests`:
```swift
        .testTarget(
            name: "ProcessControlTests",
            dependencies: ["ProcessControl", "SystemMetrics"]
        ),
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ProcessControlTests/ProcessControlTests.swift`:

```swift
import Darwin
import Foundation
import ProcessControl
import SystemMetrics
import Testing

/// Every test here signals only a `/bin/sleep` it spawned itself. The one
/// exception targets pid 1 to prove EPERM handling, and is disabled when
/// running as root — where it would really signal launchd.
@MainActor
@Suite("Process control")
struct ProcessControlTests {

    private static func spawnSleep() throws -> Foundation.Process {
        let child = Foundation.Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        return child
    }

    private static func reap(_ child: Foundation.Process) {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }

    private static func identity(of child: Foundation.Process) throws -> ProcessIdentity {
        try #require(ProcessSampler.identity(of: child.processIdentifier))
    }

    @Test("Quit ends a non-app process with SIGTERM")
    func quitSendsSIGTERM() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        try ProcessControl.perform(.quit, on: Self.identity(of: child))
        child.waitUntilExit()

        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test("Force Quit ends a process with SIGKILL")
    func forceQuitSendsSIGKILL() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        try ProcessControl.perform(.forceQuit, on: Self.identity(of: child))
        child.waitUntilExit()

        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGKILL)
    }

    /// The safety test. A pid that now belongs to a different process looks
    /// exactly like this: right pid, wrong start time. The action must be
    /// refused and the process must survive it.
    @Test("a right pid with the wrong start time is refused and the process survives")
    func staleIdentityIsRefused() throws {
        let child = try Self.spawnSleep()
        defer { Self.reap(child) }

        let real = try Self.identity(of: child)
        let stale = ProcessIdentity(pid: real.pid, startTimeSeconds: real.startTimeSeconds + 1)

        #expect(throws: ProcessControlError.exited) {
            try ProcessControl.perform(.forceQuit, on: stale)
        }
        #expect(child.isRunning)
    }

    @Test("a process that has already exited reports exited")
    func exitedProcessReportsExited() throws {
        let child = try Self.spawnSleep()
        let identity = try Self.identity(of: child)
        Self.reap(child)

        #expect(throws: ProcessControlError.exited) {
            try ProcessControl.perform(.quit, on: identity)
        }
    }

    @Test("signalling another user's process reports not permitted",
          .enabled(if: getuid() != 0, "as root this would really signal launchd"))
    func otherUsersProcessIsNotPermitted() throws {
        let launchd = try #require(ProcessSampler.identity(of: 1))

        #expect(throws: ProcessControlError.notPermitted) {
            try ProcessControl.perform(.quit, on: launchd)
        }
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter ProcessControlTests`
Expected: build FAILS — `Sources/ProcessControl` has no sources / `no such module 'ProcessControl'`.

- [ ] **Step 4: Implement**

Create `Sources/ProcessControl/ProcessControl.swift`:

```swift
import AppKit
import Darwin
import SystemMetrics

public enum ProcessAction: Sendable, Equatable {
    /// A polite request: ⌘Q's Apple event for a GUI app, `SIGTERM` otherwise.
    case quit
    /// `SIGKILL`. Cannot be caught; unsaved work is lost.
    case forceQuit
}

public enum ProcessControlError: Error, Equatable, Sendable {
    /// The process is gone, or its pid now belongs to a different process.
    case exited
    /// `EPERM` — the process is not ours to signal.
    case notPermitted
    /// `NSRunningApplication.terminate()` returned false: the quit request
    /// could not be sent. Its own case rather than `.failed(errno: 0)`, since
    /// there is no errno and `0` would be an invented one.
    case quitRequestNotSent
    case failed(errno: Int32)
}

/// Sends Quit / Force Quit to one process, identified by pid AND start time.
///
/// Main-actor because `NSRunningApplication` is AppKit, and every caller is
/// a view acting on a user's click.
@MainActor
public enum ProcessControl {

    /// Re-checks `identity` against the kernel, then acts.
    ///
    /// The identity passed in may be minutes old — it is captured at
    /// right-click and held while a confirmation alert is open. In that time
    /// the process can exit and its pid be reused, so it is read afresh here,
    /// immediately before signalling. A missing process and a pid with a
    /// different start time both throw `.exited`: in the second case the pid
    /// belongs to someone else now, and signalling it would be an action aimed
    /// at the wrong process.
    ///
    /// A window of microseconds remains between the re-check and the signal.
    /// macOS gives an unprivileged, unentitled app no stable handle on
    /// another process, so it cannot be closed; the re-check shrinks it from
    /// "however long the alert was open" to that.
    public static func perform(
        _ action: ProcessAction,
        on identity: ProcessIdentity
    ) throws(ProcessControlError) {
        guard ProcessSampler.identity(of: identity.pid) == identity else {
            throw .exited
        }

        switch action {
        case .quit:
            // A GUI app gets the same request ⌘Q sends, so it can stop to ask
            // about unsaved work. Background-only apps (`.prohibited`) and
            // plain processes have no such handler; they get SIGTERM.
            if let app = NSRunningApplication(processIdentifier: identity.pid),
               app.activationPolicy != .prohibited {
                guard app.terminate() else { throw .quitRequestNotSent }
            } else {
                try send(SIGTERM, to: identity.pid)
            }
        case .forceQuit:
            try send(SIGKILL, to: identity.pid)
        }
    }

    private static func send(_ signal: Int32, to pid: pid_t) throws(ProcessControlError) {
        guard kill(pid, signal) != 0 else { return }
        switch errno {
        case ESRCH: throw .exited
        case EPERM: throw .notPermitted
        case let code: throw .failed(errno: code)
        }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter ProcessControlTests`
Expected: 5 tests PASS (or 4 passed + 1 skipped if running as root). Confirm the summary line says 5 tests — **not** 0.

- [ ] **Step 6: Prove the safety test can go red**

Temporarily comment out the `guard ProcessSampler.identity(of:) == identity else { throw .exited }` in `perform`.

Run: `swift test --filter ProcessControlTests`
Expected: `staleIdentityIsRefused` FAILS — no error thrown and `child.isRunning` is false (it was SIGKILLed). Restore the guard, rerun, all PASS.

- [ ] **Step 7: Clean build, full suite, commit**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected: `0`. Run `swift test` — all pass.

```bash
git add -A VitalsCore
git commit -m "feat: ProcessControl target with identity-checked Quit and Force Quit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2b: Zombies are exited processes — stop listing them with a fabricated 0-byte footprint

**Added during execution** (Task 2 review round 2). A zombie — a process that
has exited but not yet been reaped by its parent — still appears in
`KERN_PROC_ALL`, and `proc_pid_rusage` on it succeeds with
`ri_phys_footprint == 0`. `ProcessSampler.detail(for:)` passes that through,
so the Processes table shows the zombie using **0 bytes**: a value the machine
never measured. This is the real cause of the intermittent
`ProcessTests.swift:85` (`footprintIsNeverZero`) failure, previously written
off as load. `ProcessControlTests` creates zombies on purpose (killed children
awaiting Foundation's reaper), which raises its hit rate.

A zombie has exited. It is treated exactly like a process that vanished
between enumeration and inspection (`ESRCH`): not listed, and no identity.
That second half also makes `ProcessControl`'s re-check refuse a zombie with
`.exited`, and makes `ProcessControlTests.staleIdentityIsRefused`'s survival
check sound (the reviewer showed a wrongly-killed but unreaped child still
passed `identity(of:) == real`).

**Files:**
- Modify: `Sources/SystemMetrics/Processes/ProcessSampler.swift`
- Modify: `Sources/ProcessControl/ProcessControl.swift` (doc comments only)
- Modify: `Tests/ProcessControlTests/ProcessControlTests.swift` (comment only)
- Test: `Tests/SystemMetricsTests/ProcessTests.swift`

**Interfaces:**
- Consumes: `ProcessSampler.kernelProcess(pid:)`, `identity(of:)`, `detail(for:)` (Task 1).
- Produces: `ProcessSampler.snapshot()` never lists a zombie; `ProcessSampler.identity(of:)` returns `nil` for a zombie. `kernelProcess(pid:)` becomes `internal` (was `private`) so the test can observe the zombie state. New `static func isZombie(_ process: kinfo_proc) -> Bool` (internal).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SystemMetricsTests/ProcessTests.swift`, inside `struct ProcessTests`, after the single-process-read tests:

```swift
    // MARK: Zombies

    /// A deterministic zombie: spawned with `posix_spawn` (not
    /// `Foundation.Process`, whose background reaper would collect it at an
    /// unpredictable moment), killed, and deliberately NOT reaped until the
    /// test ends. Returns once the kernel reports it as `SZOMB`.
    private static func makeZombie() throws -> pid_t {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
        defer { argv.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, nil) == 0)
        kill(pid, SIGKILL)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let process = ProcessSampler.kernelProcess(pid: pid), ProcessSampler.isZombie(process) {
                return pid
            }
            usleep(10_000)
        }
        Issue.record("child \(pid) never became a zombie")
        return pid
    }

    private static func reapZombie(_ pid: pid_t) {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// The cause of the old intermittent `footprintIsNeverZero` failure: a
    /// zombie's rusage reads back a zero footprint, which would be listed as
    /// "uses 0 bytes" — a value nobody measured.
    @Test("a zombie is not listed: it has exited, and its zeroed rusage is not a reading")
    func zombieIsNotListed() throws {
        let pid = try Self.makeZombie()
        defer { Self.reapZombie(pid) }

        #expect(!ProcessSampler.snapshot().contains { $0.pid == pid })
    }

    /// A zombie has no identity, so `ProcessControl`'s pre-signal re-check
    /// reports it as exited rather than "successfully" signalling a corpse.
    @Test("a zombie has no identity")
    func zombieHasNoIdentity() throws {
        let pid = try Self.makeZombie()
        defer { Self.reapZombie(pid) }

        #expect(ProcessSampler.identity(of: pid) == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ProcessTests`
Expected: build FAILS first (`kernelProcess` is private, `isZombie` does not exist). Make ONLY these two changes to get it compiling — change `private static func kernelProcess` to `static func kernelProcess`, and add:

```swift
    /// A process that has exited but not yet been reaped by its parent.
    /// It still appears in `KERN_PROC_ALL`, and `proc_pid_rusage` on it
    /// succeeds with every counter zeroed — including a 0-byte footprint the
    /// process never had. It has exited: treat it exactly as gone.
    static func isZombie(_ process: kinfo_proc) -> Bool {
        Int32(process.kp_proc.p_stat) == SZOMB
    }
```

Rerun. Expected: compiles; `zombieIsNotListed` and `zombieHasNoIdentity` both FAIL.

- [ ] **Step 3: Implement**

In `detail(for:)`, directly after `guard pid > 0 else { return nil }`:

```swift
        // Exited, awaiting reap: skipped as gone, like ESRCH below. Its
        // rusage would read back a zeroed footprint and CPU time.
        guard !isZombie(process) else { return nil }
```

In `identity(of:)`, change the guard to:

```swift
        guard let process = kernelProcess(pid: pid), !isZombie(process) else { return nil }
```

and add to its doc comment: `A zombie has exited, so it has no identity either.`

Update `kernelProcess(pid:)`'s doc comment to add: `Internal (not private) so tests can observe a zombie's state.`

- [ ] **Step 4: Tidy the two `ProcessControl` comments the review flagged**

In `Sources/ProcessControl/ProcessControl.swift`, replace the `notSignallable` doc comment with:

```swift
    /// A pid `kill(2)` would not read as one process: 0 means "every process
    /// in the caller's own process group" (so signalling `kernel_task` would
    /// hit Vitals itself), and a negative pid means a whole process group —
    /// `-1` is every process the user owns. Refused before any identity check
    /// or signal.
```

In `Tests/ProcessControlTests/ProcessControlTests.swift` (`staleIdentityIsRefused`), replace the three-line comment above `#expect(ProcessSampler.identity(of: real.pid) == real)` with:

```swift
        // Not `child.isRunning`: Foundation.Process updates it asynchronously.
        // The kernel re-read is sound because `identity(of:)` returns nil for
        // a zombie — a wrongly-killed, not-yet-reaped child fails this check.
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter ProcessTests` — expected PASS including both zombie tests. Run: `swift test --filter ProcessControlTests` — expected 6 PASS.

- [ ] **Step 6: Prove the survival check can now go red**

Temporarily comment out the identity guard in `ProcessControl.perform` (the `guard ProcessSampler.identity(of: identity.pid) == identity` line — NOT the `pid > 0` guard). Run `swift test --filter ProcessControlTests`: `staleIdentityIsRefused` must fail on BOTH expectations (no error thrown, AND the identity re-read is nil). Restore; rerun; PASS.

- [ ] **Step 7: Clean build, full suite ×3, commit**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected `0`. Run `swift test` three times, saving each log; record the name of any failing test. `ProcessTests.swift:85` should no longer fail.

```bash
git add -A VitalsCore
git commit -m "fix: zombies are exited processes, not 0-byte ones

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `ProcessRow.userID` and the pure `ProcessMenu` model

**Files:**
- Modify: `Sources/VitalsUI/Pages/Processes/ProcessRow.swift`
- Create: `Sources/VitalsUI/Pages/Processes/ProcessMenu.swift`
- Modify: `Tests/VitalsUITests/ProcessTableTests.swift` (both `row(...)` fixtures)
- Modify: `Tests/VitalsUITests/ProcessSortTests.swift` (its `row(...)` fixture)
- Test: `Tests/VitalsUITests/ProcessMenuTests.swift`

**Interfaces:**
- Consumes: `ProcessControlError`, `ProcessAction` (Task 2); `ProcessIdentity` (Task 1).
- Produces (module `VitalsUI`):
  - `ProcessRow.userID: uid_t`; memberwise `init` gains `userID: uid_t` directly after `userName:`.
  - `public enum QuitUnavailableReason: Equatable, Sendable { case systemCritical, isVitals, needsAdministrator; var explanation: String }`
  - `public struct ProcessMenuState: Equatable, Sendable { var quitUnavailable: QuitUnavailableReason?; var canReveal: Bool }`
  - `struct PendingProcessAction: Equatable { let identity: ProcessIdentity; let name: String; let action: ProcessAction }`
  - `public enum ProcessMenu` with:
    - `static func state(for row: ProcessRow, currentUserID: uid_t, ownPID: pid_t, executablePath: String?) -> ProcessMenuState`
    - `static let confirmationTitle: String`
    - `static func confirmationMessage(name: String, pid: pid_t) -> String`
    - `static let failureTitle: String`
    - `static func failureMessage(_ error: ProcessControlError, name: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VitalsUITests/ProcessMenuTests.swift`:

```swift
import Darwin
import Foundation
import ProcessControl
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process menu")
struct ProcessMenuTests {

    private static let me: uid_t = 501
    private static let vitalsPID: pid_t = 4242

    private func row(pid: pid_t, userID: uid_t) -> ProcessRow {
        ProcessRow(
            pid: pid, name: "p", userName: "u", userID: userID, cpuFraction: nil,
            memoryBytes: nil, threadCount: nil, cpuTimeSeconds: nil, diskReadBytes: nil,
            diskWrittenBytes: nil, architecture: .native, startTimeSeconds: 1_700_000_000
        )
    }

    private func state(pid: pid_t, userID: uid_t, path: String? = "/bin/sleep") -> ProcessMenuState {
        ProcessMenu.state(
            for: row(pid: pid, userID: userID),
            currentUserID: Self.me, ownPID: Self.vitalsPID, executablePath: path
        )
    }

    // MARK: Rules

    @Test("your own ordinary process can be quit")
    func ownProcessIsQuittable() {
        #expect(state(pid: 900, userID: Self.me).quitUnavailable == nil)
    }

    @Test("another user's process needs administrator access")
    func otherUserNeedsAdministrator() {
        #expect(state(pid: 900, userID: 502).quitUnavailable == .needsAdministrator)
    }

    @Test("a root process needs administrator access")
    func rootNeedsAdministrator() {
        #expect(state(pid: 900, userID: 0).quitUnavailable == .needsAdministrator)
    }

    /// pid 1 is root-owned, but "needs administrator access" would be false:
    /// root cannot usefully quit launchd either. System-critical wins.
    @Test("kernel_task and launchd are system-critical, not merely root's")
    func systemCriticalBeatsOwnership() {
        #expect(state(pid: 0, userID: 0).quitUnavailable == .systemCritical)
        #expect(state(pid: 1, userID: 0).quitUnavailable == .systemCritical)
    }

    @Test("Vitals cannot quit itself from its own table")
    func vitalsItselfIsExcluded() {
        #expect(state(pid: Self.vitalsPID, userID: Self.me).quitUnavailable == .isVitals)
    }

    @Test("Reveal in Finder is available exactly when the path is readable")
    func revealFollowsPath() {
        #expect(state(pid: 900, userID: Self.me, path: "/bin/sleep").canReveal)
        #expect(!state(pid: 900, userID: Self.me, path: nil).canReveal)
    }

    // MARK: Strings

    @Test("each unavailable reason explains itself")
    func reasonsExplainThemselves() {
        #expect(QuitUnavailableReason.systemCritical.explanation == "System process — can’t be quit")
        #expect(QuitUnavailableReason.isVitals.explanation == "Quit Vitals from its app menu")
        #expect(QuitUnavailableReason.needsAdministrator.explanation
                == "Quitting this process needs administrator access")
    }

    @Test("the confirmation names the process and its pid")
    func confirmationNamesProcess() {
        #expect(ProcessMenu.confirmationMessage(name: "sleep", pid: 4312)
                == "“sleep” (PID 4312). Force Quit stops it immediately; unsaved changes may be lost.")
    }

    @Test("each failure says why, in words")
    func failureMessages() {
        #expect(ProcessMenu.failureMessage(.exited, name: "sleep")
                == "“sleep” couldn’t be quit because it has already exited.")
        #expect(ProcessMenu.failureMessage(.notPermitted, name: "sleep")
                == "“sleep” couldn’t be quit because you don’t have permission.")
        #expect(ProcessMenu.failureMessage(.notSignallable, name: "kernel_task")
                == "“kernel_task” is a system process and can’t be quit.")
        #expect(ProcessMenu.failureMessage(.quitRequestNotSent, name: "Safari")
                == "“Safari” couldn’t be asked to quit. Try Force Quit.")
        #expect(ProcessMenu.failureMessage(.failed(errno: EINVAL), name: "sleep")
                == "“sleep” couldn’t be quit: \(String(cString: strerror(EINVAL))).")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ProcessMenuTests`
Expected: build FAILS — `extra argument 'userID'`, `cannot find 'ProcessMenu'`.

- [ ] **Step 3: Add `userID` to `ProcessRow`**

In `Sources/VitalsUI/Pages/Processes/ProcessRow.swift`:

After `public let userName: String` add:
```swift
    /// The owning user's uid. `userName` is for display; this is what decides
    /// whether the process is yours to quit — two users can share a display
    /// name, never a uid.
    public let userID: uid_t
```

In the memberwise `init`, add the parameter directly after `userName: String,`:
```swift
        userID: uid_t,
```
and the assignment directly after `self.userName = userName`:
```swift
        self.userID = userID
```

In `init(snapshot:cpuFraction:userName:)`, add after `userName: userName,`:
```swift
            userID: snapshot.userID,
```

- [ ] **Step 4: Update the test fixtures**

`Tests/VitalsUITests/ProcessTableTests.swift` — in BOTH private `row(...)` helpers, change `userName: "u", cpuFraction:` to `userName: "u", userID: 501, cpuFraction:`.

`Tests/VitalsUITests/ProcessSortTests.swift` — in its `row(...)` helper, change `pid: pid, name: name, userName: user, cpuFraction: cpu,` to `pid: pid, name: name, userName: user, userID: 501, cpuFraction: cpu,`.

Run `grep -rn "ProcessRow(" Tests` and confirm no other memberwise call sites exist (the `ProcessRow(snapshot:...)` calls in `ProcessRowTests.swift` are unaffected).

- [ ] **Step 5: Implement `ProcessMenu`**

Create `Sources/VitalsUI/Pages/Processes/ProcessMenu.swift`:

```swift
import Darwin
import Foundation
import ProcessControl
import SystemMetrics

/// Why Quit… and Force Quit… are disabled for a row. The menu shows the
/// explanation as a disabled line, so a greyed-out Quit is never unexplained.
public enum QuitUnavailableReason: Equatable, Sendable {
    /// pid 0 or 1. Not quittable by anyone — administrator access would not
    /// help, so the menu must not suggest it would.
    case systemCritical
    /// Vitals' own process. Quitting Vitals belongs in its app menu.
    case isVitals
    /// Root's or another user's process. Goes away when the privileged helper
    /// exists.
    case needsAdministrator

    public var explanation: String {
        switch self {
        case .systemCritical: "System process — can’t be quit"
        case .isVitals: "Quit Vitals from its app menu"
        case .needsAdministrator: "Quitting this process needs administrator access"
        }
    }
}

public struct ProcessMenuState: Equatable, Sendable {
    /// `nil` means Quit… and Force Quit… are enabled.
    public var quitUnavailable: QuitUnavailableReason?
    public var canReveal: Bool
}

/// The action a confirmation alert is waiting on. Holds the identity captured
/// at right-click — `ProcessControl.perform` re-checks it on confirm.
struct PendingProcessAction: Equatable {
    let identity: ProcessIdentity
    let name: String
    let action: ProcessAction
}

/// Pure model behind the Processes context menu: what is enabled, and every
/// word the menu and its alerts say. The view only renders it.
public enum ProcessMenu {

    public static func state(
        for row: ProcessRow,
        currentUserID: uid_t,
        ownPID: pid_t,
        executablePath: String?
    ) -> ProcessMenuState {
        ProcessMenuState(
            quitUnavailable: quitUnavailableReason(for: row, currentUserID: currentUserID, ownPID: ownPID),
            canReveal: executablePath != nil
        )
    }

    /// First match wins. System-critical is checked before ownership because
    /// pids 0 and 1 are root's, and "needs administrator access" would be a
    /// false promise for them.
    private static func quitUnavailableReason(
        for row: ProcessRow, currentUserID: uid_t, ownPID: pid_t
    ) -> QuitUnavailableReason? {
        if row.pid == 0 || row.pid == 1 { return .systemCritical }
        if row.pid == ownPID { return .isVitals }
        if row.userID != currentUserID { return .needsAdministrator }
        return nil
    }

    public static let confirmationTitle = "Are you sure you want to quit this process?"

    public static func confirmationMessage(name: String, pid: pid_t) -> String {
        "“\(name)” (PID \(pid)). Force Quit stops it immediately; unsaved changes may be lost."
    }

    public static let failureTitle = "Couldn’t Quit Process"

    public static func failureMessage(_ error: ProcessControlError, name: String) -> String {
        switch error {
        case .exited:
            "“\(name)” couldn’t be quit because it has already exited."
        case .notPermitted:
            "“\(name)” couldn’t be quit because you don’t have permission."
        case .notSignallable:
            "“\(name)” is a system process and can’t be quit."
        case .quitRequestNotSent:
            "“\(name)” couldn’t be asked to quit. Try Force Quit."
        case .failed(let code):
            "“\(name)” couldn’t be quit: \(String(cString: strerror(code)))."
        }
    }
}
```

- [ ] **Step 6: Clean build (ProcessRow gained a stored property), then run**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected: `0`.

Run: `swift test --filter ProcessMenuTests` — expected 9 tests PASS (not 0).
Run: `swift test --filter ProcessTableTests` and `swift test --filter ProcessSortTests` — PASS.

- [ ] **Step 7: Prove the precedence test can go red**

Temporarily move the `.systemCritical` line below the `userID != currentUserID` line in `quitUnavailableReason`. Run `swift test --filter ProcessMenuTests`: `systemCriticalBeatsOwnership` FAILS. Restore, rerun, PASS.

- [ ] **Step 8: Full suite, commit**

Run `swift test` — all pass.

```bash
git add -A VitalsCore
git commit -m "feat: ProcessRow carries userID; pure ProcessMenu model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Wire the menu and alerts into `ProcessesPage`

**Files:**
- Modify: `Sources/VitalsUI/Pages/Processes/ProcessesPage.swift`

**Interfaces:**
- Consumes: `ProcessMenu`, `ProcessMenuState`, `QuitUnavailableReason`, `PendingProcessAction` (Task 3); `ProcessControl.perform`, `ProcessAction`, `ProcessControlError` (Task 2); `ProcessSampler.executablePath(of:)` (Task 1).

No new unit tests: every decision is in `ProcessMenu` (Task 3) and `ProcessControl` (Task 2), and a SwiftUI context menu does not render in the off-screen harness. The existing `ProcessesPageTests` render tests must stay green; Task 5 is the live check.

- [ ] **Step 1: Imports and state**

Change the import block to:
```swift
import AppKit
import MetricsEngine
import ProcessControl
import SwiftUI
import SystemMetrics
```

After `@State private var selected: ProcessIdentity?` add:
```swift
    /// The Quit / Force Quit awaiting confirmation. Holds the identity captured
    /// at right-click; `ProcessControl.perform` re-checks it on confirm, so an
    /// alert left open while the process exits cannot act on a recycled pid.
    @State private var pendingAction: PendingProcessAction?

    /// A failed action's explanation, shown in its own alert. Never silent.
    @State private var failureMessage: String?
```

- [ ] **Step 2: Thread the unfiltered rows down to the table**

The menu resolves a right-clicked pid through the UNFILTERED rows, as the selection binding does. In `body`, change the `content(...)` call to:
```swift
            content(rows: rows, all: all, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum, selection: selection)
```

Change `content`'s signature and its `table(...)` call:
```swift
    @ViewBuilder
    private func content(
        rows: [ProcessRow], all: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?,
        selection: Binding<pid_t?>
    ) -> some View {
```
```swift
            table(rows: rows, all: all, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum, selection: selection)
```

Change `table`'s signature:
```swift
    private func table(
        rows: [ProcessRow], all: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?,
        selection: Binding<pid_t?>
    ) -> some View {
```

At the end of `table`, replace
```swift
        }
        .monospacedDigit()
    }
```
with
```swift
        }
        .contextMenu(forSelectionType: pid_t.self) { pids in
            // Single selection: the set is the right-clicked row, or empty
            // when the click landed below the last row (no menu then).
            if let pid = pids.first {
                processMenu(for: pid, in: all)
            }
        }
        .monospacedDigit()
    }
```

- [ ] **Step 3: The menu itself**

Add below `table(...)`:

```swift
    /// The context menu for one right-clicked pid.
    ///
    /// Resolved through the unfiltered rows to a full row — and so to an
    /// identity — before anything is offered. The executable path is read
    /// here, for this one process when the menu opens, never per tick.
    @ViewBuilder
    private func processMenu(for pid: pid_t, in all: [ProcessRow]) -> some View {
        if let row = all.first(where: { $0.pid == pid }) {
            let path = ProcessSampler.executablePath(of: row.pid)
            let state = ProcessMenu.state(
                for: row, currentUserID: getuid(), ownPID: getpid(), executablePath: path
            )

            Button("Copy PID") { copyToPasteboard("\(row.pid)") }
            Button("Copy Name") { copyToPasteboard(row.name) }
            Button("Reveal in Finder") { reveal(pid: row.pid, executablePath: path) }
                .disabled(!state.canReveal)

            Divider()

            Button("Quit…") {
                pendingAction = PendingProcessAction(identity: row.identity, name: row.name, action: .quit)
            }
            .disabled(state.quitUnavailable != nil)
            Button("Force Quit…") {
                pendingAction = PendingProcessAction(identity: row.identity, name: row.name, action: .forceQuit)
            }
            .disabled(state.quitUnavailable != nil)

            if let reason = state.quitUnavailable {
                Divider()
                Text(reason.explanation)
            }
        } else {
            Text("Process has exited")
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Selects the app bundle for a GUI app (`Safari.app`, not the binary
    /// inside it), otherwise the executable. Only reachable when `path` is
    /// non-nil — the menu disables the item otherwise.
    private func reveal(pid: pid_t, executablePath path: String?) {
        guard let path else { return }
        let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
            ?? URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func perform(_ action: ProcessAction, on pending: PendingProcessAction) {
        do {
            try ProcessControl.perform(action, on: pending.identity)
        } catch {
            failureMessage = ProcessMenu.failureMessage(error, name: pending.name)
        }
        // No optimistic removal: the next sample shows the row gone — or
        // still running, if the app stopped to ask about saving.
    }
```

- [ ] **Step 4: The two alerts**

In `body`, after the `.padding(Vitals.Metrics.contentPadding)` modifier on the `VStack`, add:

```swift
        .alert(
            ProcessMenu.confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { pending in
            // The item the user chose is the default button, so Return
            // confirms exactly what they asked for.
            Button("Force Quit", role: .destructive) { perform(.forceQuit, on: pending) }
                .keyboardShortcut(pending.action == .forceQuit ? .defaultAction : nil)
            Button("Cancel", role: .cancel) {}
            Button("Quit") { perform(.quit, on: pending) }
                .keyboardShortcut(pending.action == .quit ? .defaultAction : nil)
        } message: { pending in
            Text(ProcessMenu.confirmationMessage(name: pending.name, pid: pending.identity.pid))
        }
        .alert(
            ProcessMenu.failureTitle,
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            ),
            presenting: failureMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
```

- [ ] **Step 5: Build clean and run the suite**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```
Expected: `0`. If `.keyboardShortcut(_: KeyboardShortcut?)` does not type-check with the ternary, write it as `.keyboardShortcut(pending.action == .quit ? KeyboardShortcut.defaultAction : nil)`.

Run `swift test --filter ProcessesPageTests` — PASS. Run `swift test` — all pass.

- [ ] **Step 6: Commit**

```bash
git add -A VitalsCore
git commit -m "feat: Processes context menu with confirmed Quit and Force Quit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Live check and docs

Needs a GUI session and an unlocked screen. Performed by the controller, not a subagent.

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Build and launch the bundle**

```bash
./scripts/build-app.sh && open build/Vitals.app
```
(Not `swift run VitalsApp` — it shows no window.) Start a target in Terminal: `sleep 600 &` and note its pid. Navigate to Processes and filter to `sleep`. Confirm via the accessibility API that the Processes page is the one selected before trusting any screenshot.

- [ ] **Step 2: Walk the checklist**

1. Right-click the `sleep` row → **Copy PID**; `pbpaste` prints its pid. **Copy Name** → `sleep`.
2. **Reveal in Finder** → Finder selects `/bin/sleep`.
3. **Quit…** → the alert reads "Are you sure you want to quit this process?" / "“sleep” (PID n)…", with Quit as the default (blue) button. Confirm → the row disappears within one sample; `jobs` shows it terminated.
4. Start another `sleep 600 &`; **Force Quit…** → Force Quit is the default button → confirm → gone; `jobs` shows it killed.
5. Right-click a root process (e.g. `launchd`, pid 1) → Quit and Force Quit are disabled, with "System process — can’t be quit". Right-click a root daemon that is not pid 0/1 (e.g. `syslogd`) → disabled, with "Quitting this process needs administrator access".
6. Right-click Vitals' own row → disabled, with "Quit Vitals from its app menu".
7. Start `sleep 600 &`, open its **Quit…** alert, and while it is open run `kill <pid>` in Terminal. Then confirm → the failure alert says "“sleep” couldn’t be quit because it has already exited."

No real application is quit at any point.

- [ ] **Step 3: Update `AGENTS.md`**

In the Layout block, add after the `MetricsEngine/` line:
```
    ProcessControl/             Identity-checked Quit / Force Quit. Depends on
                                SystemMetrics only; the one module that acts.
```

In "Current state", change the "Complete:" sentence's "the Processes table" to "the Processes table (with selection and a context menu: Copy PID/Name, Reveal in Finder, confirmed Quit / Force Quit)".

Under "Known gaps", replace the bullet beginning "The Processes table has no `selection:` binding." with:
```
- The Processes context menu covers Copy PID/Name, Reveal in Finder, Quit and
  Force Quit, on your own processes only. Suspend/Resume, renice, Sample,
  Spindump and Inspect are still to come; acting on root's or other users'
  processes needs the privileged helper. Add signal-based actions to
  `ProcessControl`, and keep every one of them behind its identity re-check.
```

In "Four commands that lie to you" item 4's final paragraph, change `MetricsStoreTests.swift:563` to `MetricsStoreTests.swift:618`.

In "Platform notes worth knowing", add a bullet:
```
- **Zombies read back as zeroes.** A process that has exited but not been
  reaped still appears in `KERN_PROC_ALL`, and `proc_pid_rusage` on it
  succeeds with a 0-byte footprint and zero CPU time. `ProcessSampler` skips
  `SZOMB` processes and gives them no identity. The intermittent
  `ProcessTests` "footprint … never zero" failure was this, not load.
```

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs: AGENTS.md for the Processes context menu

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
