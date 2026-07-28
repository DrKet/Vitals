# Processes Table Implementation Plan (M1-B-3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read-only live process table described in `docs/superpowers/specs/2026-07-28-processes-table-design.md` — the "what is eating my machine" view.

**Architecture:** All sampling already exists; `MetricsEngine` publishes `.processes` at the slow cadence carrying `ProcessSeriesSample`. This plan adds store support, then four small pure units (user-name resolution, a row view model, a sort comparator, and table maths), then the SwiftUI `Table` view that composes them, then the shell wiring. Every interesting decision — absence, ordering, heat-map scaling — lives in a pure function with direct tests, so the view layer stays thin.

**Tech Stack:** Swift 6, SwiftUI `Table` (NSTableView-backed), Observation, Swift Testing.

## Global Constraints

- **Platform floor:** macOS 26.0. Swift language mode 6, strict concurrency.
- **No third-party dependencies.** Foundation, SwiftUI, Observation, Darwin, IOKit, Metal, Swift Testing only.
- **Never fabricate a number.** An unmeasurable value is `nil` and renders as an em dash — never `0`, never blank. A process whose CPU time is unreadable must never sort or display as idle.
- **Subscription-driven.** The page subscribes only to `.processes`, via `.task { await store.stream(.processes) }`, and releases it when it disappears.
- **Build and test output must be pristine** — no warnings. **Check with a clean build**: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`. An incremental build does not re-emit warnings for unchanged files.
- **`swift test --filter` matches type identifiers, not `@Suite` display names.** `--filter ProcessSortTests` works; `--filter "Process sort"` matches zero tests and still reports success. A run reporting "Test run with 0 tests ... passed" is a failure to run.
- **Use a tolerance comparison, not `==`, on any float assertion.**
- **`regionHasContent` is vacuous inside a `GlassPanel`** — it references the corner pixel at (0,0) and a panel's material fill always differs from it. Use `regionHasSaturatedColor` for anything inside a panel.
- **Package root:** `VitalsCore/`. Paths are relative to the repository root.
- **Test command:** `cd VitalsCore && swift test`.

## Consumed API (verified against the built package)

```swift
// MetricsEngine
public struct ProcessSeriesSample: Sendable {
    public let processes: [ProcessSnapshot]
    public let cpuUsage: [pid_t: Double]      // 1.0 == one core saturated
}
public enum SeriesKey { case cpu, memory, gpu, storage, network, processes, diskIO }

// SystemMetrics
public enum ProcessArchitecture: Sendable, Equatable { case native, translated }
public struct ProcessSnapshot: Sendable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let name: String
    public let userID: uid_t
    public let memoryFootprintBytes: UInt64?
    public let cpuTimeSeconds: Double?
    public let threadCount: Int?
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?
    public let architecture: ProcessArchitecture
    public init(pid:parentPID:name:userID:memoryFootprintBytes:cpuTimeSeconds:
                threadCount:diskBytesRead:diskBytesWritten:architecture:)
}

// VitalsUI
public enum Vitals {
    public static func formatByteCount<T: BinaryInteger>(_ bytes: T?) -> String?
    public static func formatKnownByteCount<T: BinaryInteger>(_ bytes: T) -> String
    public enum Palette { static let cpu, memory, gpu, storage, network, legibilityAccent, warning: Color }
    public enum Typography { static let label, sectionTitle, tileValue, readout: Font }
    public enum Metrics { static let cornerRadius, tileSpacing, contentPadding, chartHeight: CGFloat }
}
public struct MetricTile { public static func displayValue(_ value: String?) -> String }  // nil -> em dash
public struct StatRow { public static func displayValue(_ value: String?) -> String }     // nil -> "Unavailable"
```

## File Structure

The five existing pages sit flat in `Sources/VitalsUI/Pages/`. This feature has five
files, so it gets its own subdirectory to keep that directory readable.

| File | Responsibility |
|---|---|
| `Pages/Processes/UserNameResolver.swift` | uid → login name, cached |
| `Pages/Processes/ProcessRow.swift` | One table row: values plus display formatting |
| `Pages/Processes/ProcessSort.swift` | Sort field enum and the unknowns-last comparator |
| `Pages/Processes/ProcessTable.swift` | Pure table maths: filtering, order-holding, heat-map scale |
| `Pages/Processes/ProcessesPage.swift` | The SwiftUI `Table` view and its states |

Modified: `MetricsStore.swift`, `Shell/SidebarSection.swift`, `Shell/AppShell.swift`.

---

### Task 1: Store support for the processes series

`MetricsStore.apply(_:for:)` currently drops `.processes` on the floor with a comment saying the pane is M1-B-3. This is that milestone.

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/MetricsStore.swift`
- Test: `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `ProcessSeriesSample` from `MetricsEngine`.
- Produces: `MetricsStore.processes: ProcessSeriesSample?`. Tasks 5 and 6 read it.

**Note:** latest-only, deliberately **no history**. A 600-sample ring of 600 processes is 360,000 snapshots for a table that only shows the present — the same reasoning that gave `volumes` no history.

- [ ] **Step 1: Write the failing test**

Add to `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`, inside the existing `MetricsStoreTests` suite:

```swift
    @Test("publishes the latest process listing")
    func publishesProcesses() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let snapshot = ProcessSnapshot(
            pid: 42, parentPID: 1, name: "loginwindow", userID: 501,
            memoryFootprintBytes: 12_000_000, cpuTimeSeconds: 3.5, threadCount: 4,
            diskBytesRead: 1024, diskBytesWritten: 2048, architecture: .native
        )
        let sample = ProcessSeriesSample(processes: [snapshot], cpuUsage: [42: 0.25])
        await engine.register(AnySampler { sample }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()

        #expect(store.processes?.processes.count == 1)
        #expect(store.processes?.processes.first?.name == "loginwindow")
        #expect(abs((store.processes?.cpuUsage[42] ?? 0) - 0.25) < 1e-9)
    }

    @Test("a wrong-type processes payload is ignored rather than crashing")
    func wrongTypeProcessPayloadIgnored() async throws {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { "not a process sample" }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)

        let task = Task { await store.stream(.processes) }
        try await waitUntilAsync { await engine.sampleCount(for: .processes) > 0 }
        task.cancel()

        #expect(store.processes == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: FAIL — `value of type 'MetricsStore' has no member 'processes'`.

- [ ] **Step 3: Add the stored property**

In `VitalsCore/Sources/VitalsUI/MetricsStore.swift`, beside the other live fields:

```swift
    /// Latest process listing. Deliberately no history: a 600-sample ring of
    /// ~600 processes would be 360,000 snapshots for a table that only ever
    /// shows the present. Same reasoning as `volumes`.
    public private(set) var processes: ProcessSeriesSample?
```

- [ ] **Step 4: Replace the discarding `.processes` arm**

In `apply(_:for:)`, replace the existing arm:

```swift
        case .processes:
            // The Processes pane is M1-B-3. Ignored rather than crashed on, so
            // a page that subscribes early does not fault.
            return
```

with:

```swift
        case .processes:
            guard let sample = value.value as? ProcessSeriesSample else { return }
            processes = sample
            armStalenessWatch(for: key)
```

- [ ] **Step 5: Make the series expire when stale**

`.processes` is currently exempt from the liveness gate because it had no live field. It has one now, and a stale listing must not read as current. In `expiresWhenStale`, change:

```swift
        case .storage, .processes: false
        case .cpu, .memory, .gpu, .network, .diskIO: true
```

to:

```swift
        case .storage: false
        case .cpu, .memory, .gpu, .network, .diskIO, .processes: true
```

and in `clearLiveSample(for:)` replace the `case .processes: break` arm with:

```swift
        case .processes: processes = nil
```

removing the comment above it that calls the arm unreachable, since it no longer is.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: PASS, including the pre-existing staleness and volumes tests.

- [ ] **Step 7: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/MetricsStore.swift VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift
git commit -m "feat: publish the process listing from the store"
```

---

### Task 2: User name resolution

`ProcessSnapshot` carries `userID: uid_t`. A column of `0` and `501` is not useful, so uids resolve to login names.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/Processes/UserNameResolver.swift`
- Test: `VitalsCore/Tests/VitalsUITests/UserNameResolverTests.swift`

**Interfaces:**
- Produces: `@MainActor final class UserNameResolver { init(); func name(for uid: uid_t) -> String }`. Task 5 uses it.

**Note:** a uid with no passwd entry renders as the **numeric uid**, not an em dash. The value is known; only its name is missing, and those are different facts.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/UserNameResolverTests.swift`:

```swift
import Darwin
import Testing
@testable import VitalsUI

@MainActor
@Suite("User name resolution")
struct UserNameResolverTests {

    @Test("uid 0 resolves to root on every macOS system")
    func rootResolves() {
        #expect(UserNameResolver().name(for: 0) == "root")
    }

    @Test("the current user's uid resolves to a non-empty name")
    func currentUserResolves() {
        let name = UserNameResolver().name(for: getuid())
        #expect(!name.isEmpty)
        // Must be a real name, not the numeric fallback.
        #expect(name != "\(getuid())")
    }

    @Test("a uid with no passwd entry falls back to the number, not an em dash")
    func unknownUidFallsBackToNumber() {
        // The value is known; only its name is missing. Rendering it absent
        // would claim we do not know which user owns the process.
        #expect(UserNameResolver().name(for: 999_999) == "999999")
    }

    @Test("repeated lookups of one uid are served from cache")
    func repeatedLookupsAreCached() {
        let resolver = UserNameResolver()
        let first = resolver.name(for: 0)
        let second = resolver.name(for: 0)
        #expect(first == second)
        #expect(resolver.cachedCount == 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd VitalsCore && swift test --filter UserNameResolverTests`
Expected: FAIL — `cannot find 'UserNameResolver' in scope`.

- [ ] **Step 3: Implement the resolver**

Create `VitalsCore/Sources/VitalsUI/Pages/Processes/UserNameResolver.swift`:

```swift
import Darwin
import Foundation

/// Resolves a numeric uid to its login name, caching the answer.
///
/// `getpwuid` reads the directory service, which is far too slow to call once
/// per row per tick across ~600 processes. The mapping does not change while a
/// page is open, so a plain dictionary cache is sufficient.
@MainActor
public final class UserNameResolver {

    private var cache: [uid_t: String] = [:]

    public init() {}

    /// Cached entries. Exposed for tests.
    var cachedCount: Int { cache.count }

    /// The login name for `uid`, or the uid rendered as a string when the
    /// system has no passwd entry for it.
    ///
    /// The numeric fallback is deliberate: an unknown *name* is not an unknown
    /// *owner*. Rendering an em dash here would claim we do not know who owns
    /// the process, when in fact we know exactly — we just cannot name them.
    public func name(for uid: uid_t) -> String {
        if let cached = cache[uid] { return cached }

        let resolved: String
        if let entry = getpwuid(uid), let namePointer = entry.pointee.pw_name {
            resolved = String(cString: namePointer)
        } else {
            resolved = "\(uid)"
        }

        cache[uid] = resolved
        return resolved
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd VitalsCore && swift test --filter UserNameResolverTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages/Processes/UserNameResolver.swift VitalsCore/Tests/VitalsUITests/UserNameResolverTests.swift
git commit -m "feat: resolve process uids to login names"
```

---

### Task 3: The row view model and its formatting

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessRow.swift`
- Test: `VitalsCore/Tests/VitalsUITests/ProcessRowTests.swift`

**Interfaces:**
- Consumes: `ProcessSnapshot`, `ProcessArchitecture`, `Vitals.formatByteCount`.
- Produces:

```swift
public struct ProcessRow: Identifiable, Sendable, Equatable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let userName: String
    public let cpuFraction: Double?
    public let memoryBytes: UInt64?
    public let threadCount: Int?
    public let cpuTimeSeconds: Double?
    public let diskReadBytes: UInt64?
    public let diskWrittenBytes: UInt64?
    public let architecture: ProcessArchitecture
    public init(...)                                  // memberwise, all parameters
    public static func displayValue(_ value: String?) -> String
    public static func formatCPU(_ fraction: Double?) -> String?
    public static func formatMemory(_ bytes: UInt64?) -> String?
    public static func formatCount(_ count: Int?) -> String?
    public static func formatCPUTime(_ seconds: Double?) -> String?
    public static func formatArchitecture(_ architecture: ProcessArchitecture) -> String
}
```

Tasks 4, 5 and 6 all consume `ProcessRow`.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/ProcessRowTests.swift`:

```swift
import Foundation
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process row")
struct ProcessRowTests {

    // MARK: Absence

    @Test("every optional field formats as nil when unreadable, never as zero")
    func absentFieldsFormatAsNil() {
        // A third of live processes have unreadable CPU time. Formatting any of
        // these as "0" would report a running process as idle.
        #expect(ProcessRow.formatCPU(nil) == nil)
        #expect(ProcessRow.formatMemory(nil) == nil)
        #expect(ProcessRow.formatCount(nil) == nil)
        #expect(ProcessRow.formatCPUTime(nil) == nil)
    }

    @Test("absence renders as the same em dash the tiles use")
    func absenceMatchesTileVocabulary() {
        #expect(ProcessRow.displayValue(nil) == MetricTile.displayValue(nil))
        #expect(ProcessRow.displayValue("41%") == "41%")
    }

    @Test("a genuine zero is shown as zero, not as absent")
    func genuineZeroIsNotAbsence() {
        // A process really using no CPU this interval is a measurement.
        #expect(ProcessRow.formatCPU(0) == "0%")
        #expect(ProcessRow.formatCount(0) == "0")
    }

    // MARK: CPU

    @Test("CPU is shown Activity Monitor style, where four saturated cores read 400%")
    func cpuUsesActivityMonitorScale() {
        #expect(ProcessRow.formatCPU(0.412) == "41%")
        #expect(ProcessRow.formatCPU(1.0) == "100%")
        #expect(ProcessRow.formatCPU(4.02) == "402%")
    }

    // MARK: CPU time

    @Test("CPU time is formatted as hours, minutes and seconds")
    func cpuTimeFormatting() {
        #expect(ProcessRow.formatCPUTime(0) == "0:00:00")
        #expect(ProcessRow.formatCPUTime(83) == "0:01:23")
        #expect(ProcessRow.formatCPUTime(3_723) == "1:02:03")
        #expect(ProcessRow.formatCPUTime(360_000) == "100:00:00")
    }

    // MARK: Architecture

    @Test("architecture names the thing a reader cares about")
    func architectureNaming() {
        #expect(ProcessRow.formatArchitecture(.native) == "Native")
        #expect(ProcessRow.formatArchitecture(.translated) == "Rosetta")
    }

    // MARK: Construction from a snapshot

    @Test("a row carries the snapshot's values and the CPU usage keyed to its pid")
    func rowCarriesSnapshotValues() {
        let snapshot = ProcessSnapshot(
            pid: 501, parentPID: 1, name: "Xcode", userID: 501,
            memoryFootprintBytes: 2_000_000_000, cpuTimeSeconds: 42.0, threadCount: 30,
            diskBytesRead: 4096, diskBytesWritten: 8192, architecture: .native
        )
        let row = ProcessRow(snapshot: snapshot, cpuFraction: 1.5, userName: "george")

        #expect(row.id == 501)
        #expect(row.name == "Xcode")
        #expect(row.userName == "george")
        #expect(abs((row.cpuFraction ?? 0) - 1.5) < 1e-9)
        #expect(row.memoryBytes == 2_000_000_000)
        #expect(row.threadCount == 30)
    }

    @Test("a process with no CPU entry keeps a nil fraction rather than defaulting to zero")
    func missingCPUEntryStaysNil() {
        let snapshot = ProcessSnapshot(
            pid: 7, parentPID: 1, name: "kernel_task", userID: 0,
            memoryFootprintBytes: nil, cpuTimeSeconds: nil, threadCount: nil,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native
        )
        let row = ProcessRow(snapshot: snapshot, cpuFraction: nil, userName: "root")
        #expect(row.cpuFraction == nil)
        #expect(row.memoryBytes == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd VitalsCore && swift test --filter ProcessRowTests`
Expected: FAIL — `cannot find 'ProcessRow' in scope`.

- [ ] **Step 3: Implement the row**

Create `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessRow.swift`:

```swift
import Foundation
import SystemMetrics

/// One row of the process table: the values it shows, and how they are worded.
///
/// Deliberately free of SwiftUI, so every formatting and absence decision is a
/// pure function with a direct test — the same split the hardware pages use.
public struct ProcessRow: Identifiable, Sendable, Equatable {

    public var id: pid_t { pid }

    public let pid: pid_t
    public let name: String
    public let userName: String

    /// `1.0` means one core fully saturated, so a process spread across four
    /// cores reads `4.0`. `nil` when this process' CPU time is unreadable —
    /// which is true of roughly a third of live processes, typically other
    /// users' and root's.
    public let cpuFraction: Double?

    public let memoryBytes: UInt64?
    public let threadCount: Int?
    public let cpuTimeSeconds: Double?
    public let diskReadBytes: UInt64?
    public let diskWrittenBytes: UInt64?
    public let architecture: ProcessArchitecture

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
        architecture: ProcessArchitecture
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
    }

    public init(snapshot: ProcessSnapshot, cpuFraction: Double?, userName: String) {
        self.init(
            pid: snapshot.pid,
            name: snapshot.name,
            userName: userName,
            cpuFraction: cpuFraction,
            memoryBytes: snapshot.memoryFootprintBytes,
            threadCount: snapshot.threadCount,
            cpuTimeSeconds: snapshot.cpuTimeSeconds,
            diskReadBytes: snapshot.diskBytesRead,
            diskWrittenBytes: snapshot.diskBytesWritten,
            architecture: snapshot.architecture
        )
    }

    // MARK: Display

    /// Absence in a table cell, worded exactly as `MetricTile` words it.
    /// `PageConsistencyTests` holds the two together.
    public static func displayValue(_ value: String?) -> String {
        MetricTile.displayValue(value)
    }

    /// Activity Monitor's scale: a process saturating four cores reads 402%,
    /// not 100%. Clamping to 100 would hide the thing you opened the table for.
    public static func formatCPU(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    public static func formatMemory(_ bytes: UInt64?) -> String? {
        Vitals.formatByteCount(bytes)
    }

    public static func formatCount(_ count: Int?) -> String? {
        guard let count else { return nil }
        return "\(count)"
    }

    /// `h:mm:ss`. Hours are not zero-padded and are not capped at 24 — a
    /// long-lived daemon legitimately accumulates hundreds of hours.
    public static func formatCPUTime(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }

    public static func formatArchitecture(_ architecture: ProcessArchitecture) -> String {
        switch architecture {
        case .native: "Native"
        case .translated: "Rosetta"
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd VitalsCore && swift test --filter ProcessRowTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessRow.swift VitalsCore/Tests/VitalsUITests/ProcessRowTests.swift
git commit -m "feat: add the process row view model and its formatting"
```

---

### Task 4: The unknowns-last sort comparator

This is the task that carries the design's central honesty decision. `KeyPathComparator` cannot express it, which is why a custom comparator exists.

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessSort.swift`
- Test: `VitalsCore/Tests/VitalsUITests/ProcessSortTests.swift`

**Interfaces:**
- Consumes: `ProcessRow`.
- Produces:

```swift
public enum ProcessSortField: String, Sendable, CaseIterable {
    case name, cpu, memory, pid, user, threads, cpuTime, diskRead, diskWrite, architecture
}
public struct ProcessComparator: SortComparator, Sendable {
    public var order: SortOrder
    public let field: ProcessSortField
    public init(field: ProcessSortField, order: SortOrder)
    public func compare(_ lhs: ProcessRow, _ rhs: ProcessRow) -> ComparisonResult
}
```

Tasks 5 and 6 consume it.

**The rule:** an unreadable value sorts **after** every readable one, in both ascending and descending order. It is not folded in as zero, because "we could not read this" and "this is idle" are different claims and only one of them is true.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/ProcessSortTests.swift`:

```swift
import Foundation
import SystemMetrics
import Testing
@testable import VitalsUI

@Suite("Process sort")
struct ProcessSortTests {

    private func row(_ pid: pid_t, cpu: Double?, memory: UInt64? = 0, name: String = "p") -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: "u", cpuFraction: cpu,
            memoryBytes: memory, threadCount: nil, cpuTimeSeconds: nil,
            diskReadBytes: nil, diskWrittenBytes: nil, architecture: .native
        )
    }

    @Test("descending CPU puts the heaviest first and the unreadable last")
    func descendingPutsUnknownsLast() {
        let rows = [row(1, cpu: 0.1), row(2, cpu: nil), row(3, cpu: 2.0)]
        let sorted = rows.sorted(using: ProcessComparator(field: .cpu, order: .reverse))
        #expect(sorted.map(\.pid) == [3, 1, 2])
    }

    @Test("ascending CPU puts the lightest first and STILL puts the unreadable last")
    func ascendingAlsoPutsUnknownsLast() {
        // The point of the whole design. Flipping the sort must not promote
        // unreadable processes to the top as though they were the idlest —
        // that would assert something we did not measure.
        let rows = [row(1, cpu: 0.1), row(2, cpu: nil), row(3, cpu: 2.0)]
        let sorted = rows.sorted(using: ProcessComparator(field: .cpu, order: .forward))
        #expect(sorted.map(\.pid) == [1, 3, 2])
    }

    @Test("an unreadable value does not tie with a genuine zero")
    func unknownIsNotZero() {
        let rows = [row(1, cpu: nil), row(2, cpu: 0.0)]
        let sorted = rows.sorted(using: ProcessComparator(field: .cpu, order: .forward))
        #expect(sorted.map(\.pid) == [2, 1])
    }

    @Test("two unreadable values compare as equal, so their relative order is stable")
    func unknownsTieWithEachOther() {
        let comparator = ProcessComparator(field: .cpu, order: .forward)
        #expect(comparator.compare(row(1, cpu: nil), row(2, cpu: nil)) == .orderedSame)
    }

    @Test("memory sorts by value with unreadable last, in both directions")
    func memorySortsWithUnknownsLast() {
        let rows = [row(1, cpu: 0, memory: 500), row(2, cpu: 0, memory: nil), row(3, cpu: 0, memory: 9_000)]
        #expect(rows.sorted(using: ProcessComparator(field: .memory, order: .reverse)).map(\.pid) == [3, 1, 2])
        #expect(rows.sorted(using: ProcessComparator(field: .memory, order: .forward)).map(\.pid) == [1, 3, 2])
    }

    @Test("name sorts case-insensitively so Xcode does not outrank finder")
    func nameSortsCaseInsensitively() {
        let rows = [row(1, cpu: 0, name: "Xcode"), row(2, cpu: 0, name: "finder")]
        let sorted = rows.sorted(using: ProcessComparator(field: .name, order: .forward))
        #expect(sorted.map(\.name) == ["finder", "Xcode"])
    }

    @Test("pid is never absent, so it sorts plainly in both directions")
    func pidSortsPlainly() {
        let rows = [row(30, cpu: nil), row(2, cpu: nil), row(11, cpu: nil)]
        #expect(rows.sorted(using: ProcessComparator(field: .pid, order: .forward)).map(\.pid) == [2, 11, 30])
        #expect(rows.sorted(using: ProcessComparator(field: .pid, order: .reverse)).map(\.pid) == [30, 11, 2])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd VitalsCore && swift test --filter ProcessSortTests`
Expected: FAIL — `cannot find 'ProcessComparator' in scope`.

- [ ] **Step 3: Implement the comparator**

Create `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessSort.swift`:

```swift
import Foundation

/// Which column the table is sorted by.
public enum ProcessSortField: String, Sendable, CaseIterable {
    case name, cpu, memory, pid, user, threads, cpuTime, diskRead, diskWrite, architecture
}

/// Orders process rows, keeping unreadable values in a group of their own at
/// the end.
///
/// `KeyPathComparator` cannot express this: it would need a value to compare,
/// and the only candidate — zero — is a claim the machine never made. A process
/// whose CPU time could not be read is not idle; it is unknown, and ascending
/// order must not promote it above a process measured at 0.1%.
///
/// The unknown group therefore sits last in BOTH directions. `order` applies to
/// readable values only.
public struct ProcessComparator: SortComparator, Sendable {

    public var order: SortOrder
    public let field: ProcessSortField

    public init(field: ProcessSortField, order: SortOrder) {
        self.field = field
        self.order = order
    }

    public func compare(_ lhs: ProcessRow, _ rhs: ProcessRow) -> ComparisonResult {
        switch field {
        case .name:
            return applying(compareStrings(lhs.name, rhs.name))
        case .user:
            return applying(compareStrings(lhs.userName, rhs.userName))
        case .architecture:
            return applying(compareStrings(
                ProcessRow.formatArchitecture(lhs.architecture),
                ProcessRow.formatArchitecture(rhs.architecture)
            ))
        case .pid:
            return applying(compareValues(Double(lhs.pid), Double(rhs.pid)))
        case .cpu:
            return compareOptional(lhs.cpuFraction, rhs.cpuFraction)
        case .memory:
            return compareOptional(lhs.memoryBytes.map(Double.init), rhs.memoryBytes.map(Double.init))
        case .threads:
            return compareOptional(lhs.threadCount.map(Double.init), rhs.threadCount.map(Double.init))
        case .cpuTime:
            return compareOptional(lhs.cpuTimeSeconds, rhs.cpuTimeSeconds)
        case .diskRead:
            return compareOptional(lhs.diskReadBytes.map(Double.init), rhs.diskReadBytes.map(Double.init))
        case .diskWrite:
            return compareOptional(lhs.diskWrittenBytes.map(Double.init), rhs.diskWrittenBytes.map(Double.init))
        }
    }

    /// Presence is decided before value, and is NOT flipped by `order` — that
    /// is the whole point. Two absences tie, so their existing relative order
    /// survives a stable sort.
    private func compareOptional(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (left?, right?): return applying(compareValues(left, right))
        }
    }

    private func compareValues(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// Case-insensitive so "Xcode" files beside "finder" rather than ahead of
    /// every lowercase name.
    private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedCaseInsensitiveCompare(rhs)
    }

    private func applying(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd VitalsCore && swift test --filter ProcessSortTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Prove the tests are not vacuous**

Two mutations, because they trip different tests and only the second exercises the rule the design is actually about. Run each, observe, then restore before the next.

**Mutation A — fold `nil` in as zero.** Replace the whole `compareOptional` body with:

```swift
        applying(compareValues(lhs ?? 0, rhs ?? 0))
```

This is the bug the design exists to prevent: it treats "could not read" as "idle".

Expected: `ascendingAlsoPutsUnknownsLast` FAILS — ascending now promotes unreadable processes above one measured at 0.1%. That test is the design; if it survives this mutation, it is testing nothing.

**Mutation B — flip presence with the sort direction.** Restore, then change only `case (nil, _): return .orderedDescending` to `return applying(.orderedDescending)`.

Expected: `descendingPutsUnknownsLast` and `memorySortsWithUnknownsLast` FAIL — but `ascendingAlsoPutsUnknownsLast` **passes**. That is not a gap in the test: `applying` is a no-op when `order == .forward`, so this mutation cannot change ascending behaviour at all. What it does break is antisymmetry — one arm now says nil-first while the other still says nil-last, so the two disagree and the descending sort is corrupted rather than merely reordered.

Restore and confirm the suite is green.

Report which test went red under each mutation. If the observed behaviour differs from the above, that is a finding worth reporting, not something to reconcile silently.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessSort.swift VitalsCore/Tests/VitalsUITests/ProcessSortTests.swift
git commit -m "feat: sort unreadable process values last in both directions"
```

---

### Task 5: Table maths — rows, filtering, order-holding, heat scale

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessTable.swift`
- Test: `VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift`

**Interfaces:**
- Consumes: `ProcessSeriesSample`, `ProcessRow`, `ProcessComparator`, `UserNameResolver`.
- Produces:

```swift
public enum ProcessTable {
    @MainActor public static func rows(from sample: ProcessSeriesSample, resolver: UserNameResolver) -> [ProcessRow]
    public static func filtered(_ rows: [ProcessRow], query: String) -> [ProcessRow]
    public static func ordered(_ rows: [ProcessRow], keeping order: [pid_t]) -> [ProcessRow]
    public static func maximum(of value: (ProcessRow) -> Double?, in rows: [ProcessRow]) -> Double?
    public static func heatFraction(_ value: Double?, maximum: Double?) -> Double?
}
```

Task 6 consumes all five.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift`:

```swift
import Foundation
import MetricsEngine
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Process table")
struct ProcessTableTests {

    private func row(_ pid: pid_t, name: String = "p", cpu: Double? = 0, memory: UInt64? = 0) -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, userName: "u", cpuFraction: cpu, memoryBytes: memory,
            threadCount: nil, cpuTimeSeconds: nil, diskReadBytes: nil,
            diskWrittenBytes: nil, architecture: .native
        )
    }

    // MARK: Building rows

    @Test("a process with no CPU entry becomes a row with a nil fraction, not zero")
    func missingCPUEntryBecomesNil() {
        let snapshot = ProcessSnapshot(
            pid: 9, parentPID: 1, name: "syslogd", userID: 0,
            memoryFootprintBytes: 1000, cpuTimeSeconds: nil, threadCount: 2,
            diskBytesRead: nil, diskBytesWritten: nil, architecture: .native
        )
        let sample = ProcessSeriesSample(processes: [snapshot], cpuUsage: [:])
        let rows = ProcessTable.rows(from: sample, resolver: UserNameResolver())

        #expect(rows.count == 1)
        #expect(rows[0].cpuFraction == nil)
        #expect(rows[0].userName == "root")
    }

    // MARK: Filtering

    @Test("filtering matches a name substring, ignoring case")
    func filterMatchesNameSubstring() {
        let rows = [row(1, name: "Xcode"), row(2, name: "WindowServer"), row(3, name: "finder")]
        #expect(ProcessTable.filtered(rows, query: "wind").map(\.pid) == [2])
        #expect(ProcessTable.filtered(rows, query: "XCODE").map(\.pid) == [1])
    }

    @Test("a numeric query also matches an exact pid")
    func filterMatchesExactPID() {
        let rows = [row(42, name: "Xcode"), row(7, name: "finder")]
        #expect(ProcessTable.filtered(rows, query: "42").map(\.pid) == [42])
    }

    @Test("an empty query returns every row untouched")
    func emptyQueryReturnsEverything() {
        let rows = [row(1), row(2)]
        #expect(ProcessTable.filtered(rows, query: "").count == 2)
        #expect(ProcessTable.filtered(rows, query: "   ").count == 2)
    }

    @Test("a query matching nothing returns nothing, which is distinct from having no data")
    func nonMatchingQueryReturnsEmpty() {
        #expect(ProcessTable.filtered([row(1, name: "Xcode")], query: "zzz").isEmpty)
    }

    // MARK: Order holding

    @Test("rows keep the established order even when their values change")
    func establishedOrderIsKept() {
        // The heart of "values update, order holds": pid 3 becoming the
        // heaviest must not move it while the user is reading.
        let ordered = ProcessTable.ordered([row(3, cpu: 9.0), row(1, cpu: 0.1)], keeping: [1, 3])
        #expect(ordered.map(\.pid) == [1, 3])
    }

    @Test("a process that exits leaves its slot rather than shifting everything")
    func exitedProcessIsDropped() {
        // Input deliberately scrambled relative to the expected output. With
        // the rows already in order, an inert `ordered` that just returned its
        // input would satisfy this — the test would prove only that a missing
        // pid is not invented, which is trivially true.
        let ordered = ProcessTable.ordered([row(3), row(1)], keeping: [1, 2, 3])
        #expect(ordered.map(\.pid) == [1, 3])
    }

    @Test("a newly started process is appended, not inserted mid-table")
    func newProcessIsAppended() {
        // Scrambled for the same reason: pid 99 leads the input but must end
        // up last, so identity-passthrough gives [99, 1, 2] and fails.
        let ordered = ProcessTable.ordered([row(99), row(1), row(2)], keeping: [1, 2])
        #expect(ordered.map(\.pid) == [1, 2, 99])
    }

    @Test("with no established order the rows are returned as given")
    func emptyOrderReturnsInputOrder() {
        #expect(ProcessTable.ordered([row(5), row(2)], keeping: []).map(\.pid) == [5, 2])
    }

    // MARK: Heat map

    @Test("the largest value in a column is fully saturated and the rest are proportional")
    func heatScalesToTheColumnMaximum() {
        let rows = [row(1, cpu: 1.0), row(2, cpu: 4.0)]
        let maximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        #expect(abs((maximum ?? 0) - 4.0) < 1e-9)
        #expect(abs((ProcessTable.heatFraction(4.0, maximum: maximum) ?? 0) - 1.0) < 1e-9)
        #expect(abs((ProcessTable.heatFraction(1.0, maximum: maximum) ?? 0) - 0.25) < 1e-9)
    }

    @Test("an unreadable value gets no shading, because absence is not a low value")
    func unreadableValueHasNoShade() {
        #expect(ProcessTable.heatFraction(nil, maximum: 4.0) == nil)
    }

    @Test("a column where nothing is readable has no maximum and shades nothing")
    func allUnknownColumnHasNoMaximum() {
        let rows = [row(1, cpu: nil), row(2, cpu: nil)]
        #expect(ProcessTable.maximum(of: \.cpuFraction, in: rows) == nil)
        #expect(ProcessTable.heatFraction(nil, maximum: nil) == nil)
        #expect(ProcessTable.heatFraction(1.0, maximum: nil) == nil)
    }

    @Test("an all-zero column shades nothing rather than dividing by zero")
    func zeroMaximumShadesNothing() {
        #expect(ProcessTable.heatFraction(0, maximum: 0) == nil)
    }

    @Test("a single row is fully saturated, since it is its own maximum")
    func singleRowIsItsOwnMaximum() {
        let rows = [row(1, cpu: 0.02)]
        let maximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        #expect(abs((ProcessTable.heatFraction(0.02, maximum: maximum) ?? 0) - 1.0) < 1e-9)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd VitalsCore && swift test --filter ProcessTableTests`
Expected: FAIL — `cannot find 'ProcessTable' in scope`.

- [ ] **Step 3: Implement the table maths**

Create `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessTable.swift`:

```swift
import Foundation
import MetricsEngine

/// Pure maths behind the process table. Every decision the design makes about
/// absence, ordering and shading lives here rather than in the view, so each
/// one has a direct test.
public enum ProcessTable {

    /// Builds rows from one sample. A process absent from `cpuUsage` keeps a
    /// `nil` fraction — the sampler omits a process whose CPU time it could not
    /// read, and defaulting to zero here would undo that.
    @MainActor
    public static func rows(from sample: ProcessSeriesSample, resolver: UserNameResolver) -> [ProcessRow] {
        sample.processes.map { snapshot in
            ProcessRow(
                snapshot: snapshot,
                cpuFraction: sample.cpuUsage[snapshot.pid],
                userName: resolver.name(for: snapshot.userID)
            )
        }
    }

    /// Case-insensitive substring match on the name, plus an exact pid match
    /// when the query is a number. A blank query filters nothing.
    public static func filtered(_ rows: [ProcessRow], query: String) -> [ProcessRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }

        let pid = pid_t(trimmed)
        return rows.filter { row in
            if let pid, row.pid == pid { return true }
            return row.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Reorders `rows` to follow an established display order.
    ///
    /// This is what "values update, order holds" means: rows keep their slots
    /// while their numbers change, so a row can be read without it moving.
    /// Processes that exited drop out; processes that started are appended
    /// rather than inserted, since inserting is the same jump re-sorting would
    /// have caused.
    public static func ordered(_ rows: [ProcessRow], keeping order: [pid_t]) -> [ProcessRow] {
        guard !order.isEmpty else { return rows }

        var byPID = [pid_t: ProcessRow](minimumCapacity: rows.count)
        for row in rows { byPID[row.pid] = row }

        var result: [ProcessRow] = []
        result.reserveCapacity(rows.count)
        var placed = Set<pid_t>(minimumCapacity: rows.count)

        for pid in order {
            guard let row = byPID[pid] else { continue }   // exited since the last sort
            result.append(row)
            placed.insert(pid)
        }
        for row in rows where !placed.contains(row.pid) {  // started since the last sort
            result.append(row)
        }
        return result
    }

    /// The largest readable value in a column, or `nil` when nothing in it is
    /// readable. Computed once per sample — doing it per cell would be one
    /// pass over every row for every row.
    public static func maximum(of value: (ProcessRow) -> Double?, in rows: [ProcessRow]) -> Double? {
        rows.compactMap(value).max()
    }

    /// How saturated a heat-map cell should be, `0...1`.
    ///
    /// `nil` for an unreadable value — absence is not a low value and must not
    /// be shaded as one — and `nil` when the column has no positive maximum,
    /// which also avoids dividing by zero on an idle column.
    public static func heatFraction(_ value: Double?, maximum: Double?) -> Double? {
        guard let value, let maximum, maximum > 0 else { return nil }
        return min(max(value / maximum, 0), 1)
    }
}
```

Note the two `maximum(of:in:)` call sites in the tests pass a key path (`\.cpuFraction`); Swift converts a key path to a function automatically, so no overload is needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd VitalsCore && swift test --filter ProcessTableTests`
Expected: PASS, 14 tests.

- [ ] **Step 5: Prove the order-holding tests are not vacuous**

Temporarily make `ordered(_:keeping:)` return `rows` unchanged as its first line. Run the suite.

Expected: `establishedOrderIsKept`, `exitedProcessIsDropped` and `newProcessIsAppended` all FAIL. `emptyOrderReturnsInputOrder` correctly stays green — an inert `ordered` genuinely is right for an empty order. Restore and confirm green.

- [ ] **Step 6: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessTable.swift VitalsCore/Tests/VitalsUITests/ProcessTableTests.swift
git commit -m "feat: add process table filtering, order holding and heat scaling"
```

---

### Task 6: The page

**Files:**
- Create: `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessesPage.swift`
- Test: `VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift`

**Interfaces:**
- Consumes: `MetricsStore.processes`, `ProcessTable`, `ProcessRow`, `ProcessComparator`, `UserNameResolver`.
- Produces: `public struct ProcessesPage: View { public init(store: MetricsStore) }`. Task 7 routes to it.

**Note:** this page does **not** use `HardwarePage`. That container is built around a primary value, a chart and a stats block; a table has none of those.

- [ ] **Step 1: Write the failing test**

Create `VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift`:

```swift
import Foundation
import MetricsEngine
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("Processes page")
struct ProcessesPageTests {

    private static func snapshot(_ pid: pid_t, _ name: String, cpuTime: Double?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: 1, name: name, userID: 501,
            memoryFootprintBytes: UInt64(pid) * 1_000_000, cpuTimeSeconds: cpuTime,
            threadCount: 3, diskBytesRead: 512, diskBytesWritten: 256,
            architecture: .native
        )
    }

    private func storeWithProcesses() async throws -> MetricsStore {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let sample = ProcessSeriesSample(
            processes: [
                Self.snapshot(1, "launchd", cpuTime: 12),
                Self.snapshot(42, "Xcode", cpuTime: 900),
                Self.snapshot(77, "kernel_task", cpuTime: nil),
            ],
            cpuUsage: [1: 0.02, 42: 3.5]      // 77 deliberately unreadable
        )
        await engine.register(AnySampler { sample }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)
        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()
        return store
    }

    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFromLiveStore() async throws {
        let store = try await storeWithProcesses()
        let rendered = try renderPNG(
            ProcessesPage(store: store),
            size: CGSize(width: 900, height: 600),
            name: "processes-page-with-data"
        )
        #expect(rendered.url.isFileURL)
    }

    @Test("renders without trapping when no listing has arrived yet")
    func rendersEmptyStore() throws {
        let store = MetricsStore(
            engine: MetricsEngine(intervalOverride: .milliseconds(5)),
            profile: nil
        )
        let rendered = try renderPNG(
            ProcessesPage(store: store),
            size: CGSize(width: 900, height: 600),
            name: "processes-page-empty-store"
        )
        #expect(rendered.url.isFileURL)
    }

    @Test("the default sort is CPU descending, so the heaviest process is first")
    func defaultSortIsCPUDescending() async throws {
        let store = try await storeWithProcesses()
        let sample = try #require(store.processes)
        let rows = ProcessTable.rows(from: sample, resolver: UserNameResolver())
            .sorted(using: ProcessComparator(field: .cpu, order: .reverse))

        // Xcode heaviest, launchd next, kernel_task last because unreadable.
        #expect(rows.map(\.name) == ["Xcode", "launchd", "kernel_task"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd VitalsCore && swift test --filter ProcessesPageTests`
Expected: FAIL — `cannot find 'ProcessesPage' in scope`.

- [ ] **Step 3: Implement the page**

Create `VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessesPage.swift`:

```swift
import MetricsEngine
import SwiftUI

/// The live process table.
///
/// Deliberately not built on `HardwarePage`: that container is shaped around a
/// primary value, a chart and a stats block, and a table has none of them.
public struct ProcessesPage: View {

    private let store: MetricsStore
    @State private var resolver = UserNameResolver()
    @State private var filter = ""

    /// Bound to the `Table` so headers show and drive their sort indicators.
    /// SwiftUI types this to whatever `TableColumn(_:value:)` produces —
    /// `KeyPathComparator` — so a custom comparator cannot go here. It is
    /// translated into a `ProcessComparator` in `resort()`, which is where the
    /// unknowns-last rule is actually applied.
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuFraction, order: .reverse)]

    /// Which columns are visible. Six show by default; the other four are
    /// available from the header's context menu.
    @State private var columns = TableColumnCustomization<ProcessRow>()

    /// PIDs in the order they are currently displayed. Recomputed only when the
    /// sort changes or the view appears — between those, values refresh in
    /// place so a row can be read without it moving underneath the pointer.
    @State private var displayOrder: [pid_t] = []

    public init(store: MetricsStore) {
        self.store = store
    }

    public var body: some View {
        // Computed ONCE per body evaluation and threaded down. These were
        // computed properties in an earlier draft, which meant every heat cell
        // re-filtered, re-ordered and re-scanned all ~600 rows — thousands of
        // passes per redraw.
        let rows = orderedRows()
        let cpuMaximum = ProcessTable.maximum(of: \.cpuFraction, in: rows)
        let memoryMaximum = ProcessTable.maximum(
            of: { $0.memoryBytes.map(Double.init) }, in: rows
        )

        return VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
            header
            content(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
        }
        .padding(Vitals.Metrics.contentPadding)
        .task { await store.stream(.processes) }
        .onAppear(perform: resort)
        .onChange(of: sortOrder) { _, _ in resort() }
    }

    private func orderedRows() -> [ProcessRow] {
        guard let sample = store.processes else { return [] }
        let all = ProcessTable.rows(from: sample, resolver: resolver)
        return ProcessTable.ordered(ProcessTable.filtered(all, query: filter), keeping: displayOrder)
    }

    private var header: some View {
        HStack {
            Text("Processes").font(Vitals.Typography.sectionTitle)
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    @ViewBuilder
    private func content(
        rows: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?
    ) -> some View {
        if store.processes == nil {
            message("No process listing available.")
        } else if rows.isEmpty {
            // Distinct from having no data: this is a real listing that the
            // filter excluded everything from.
            message("No process matches “\(filter)”.")
        } else {
            table(rows: rows, cpuMaximum: cpuMaximum, memoryMaximum: memoryMaximum)
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(Vitals.Typography.label).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func table(
        rows: [ProcessRow], cpuMaximum: Double?, memoryMaximum: Double?
    ) -> some View {
        Table(rows, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Process", value: \.name) { row in
                Text(row.name).lineLimit(1)
            }
            .customizationID("name")

            TableColumn("CPU", value: \.cpuFraction) { row in
                heatCell(ProcessRow.formatCPU(row.cpuFraction),
                         heat: ProcessTable.heatFraction(row.cpuFraction, maximum: cpuMaximum))
            }
            .customizationID("cpu")

            TableColumn("Memory", value: \.memoryBytes) { row in
                heatCell(ProcessRow.formatMemory(row.memoryBytes),
                         heat: ProcessTable.heatFraction(row.memoryBytes.map(Double.init),
                                                         maximum: memoryMaximum))
            }
            .customizationID("memory")

            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)").monospacedDigit()
            }
            .customizationID("pid")

            TableColumn("User", value: \.userName) { row in
                Text(row.userName).lineLimit(1)
            }
            .customizationID("user")

            TableColumn("Threads", value: \.threadCount) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatCount(row.threadCount)))
                    .monospacedDigit()
            }
            .customizationID("threads")

            TableColumn("CPU Time", value: \.cpuTimeSeconds) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatCPUTime(row.cpuTimeSeconds)))
                    .monospacedDigit()
            }
            .customizationID("cpuTime")
            .defaultVisibility(.hidden)

            TableColumn("Disk Read", value: \.diskReadBytes) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatMemory(row.diskReadBytes)))
                    .monospacedDigit()
            }
            .customizationID("diskRead")
            .defaultVisibility(.hidden)

            TableColumn("Disk Write", value: \.diskWrittenBytes) { row in
                Text(ProcessRow.displayValue(ProcessRow.formatMemory(row.diskWrittenBytes)))
                    .monospacedDigit()
            }
            .customizationID("diskWrite")
            .defaultVisibility(.hidden)

            TableColumn("Architecture", value: \.name) { row in
                Text(ProcessRow.formatArchitecture(row.architecture))
            }
            .customizationID("architecture")
            .defaultVisibility(.hidden)
        }
        .monospacedDigit()
    }

    /// A numeric cell with the heat-map background behind it. An unreadable
    /// value gets no background at all — absence is not a low value.
    private func heatCell(_ text: String?, heat: Double?) -> some View {
        Text(ProcessRow.displayValue(text))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Vitals.Palette.cpu.opacity((heat ?? 0) * 0.35))
            )
    }

    /// Freezes a new display order from the current sort, translating SwiftUI's
    /// `KeyPathComparator` into the comparator that keeps unknowns last.
    private func resort() {
        guard let sample = store.processes else { return }
        let all = ProcessTable.rows(from: sample, resolver: resolver)
        displayOrder = ProcessTable.filtered(all, query: filter)
            .sorted(using: processComparator())
            .map(\.pid)
    }

    /// Maps the bound `KeyPathComparator` back to a `ProcessSortField`.
    /// Defaults to CPU descending if a key path is ever unrecognised, rather
    /// than leaving the table in whatever order the sampler happened to return.
    private func processComparator() -> ProcessComparator {
        guard let active = sortOrder.first else {
            return ProcessComparator(field: .cpu, order: .reverse)
        }
        let field = Self.field(for: active.keyPath) ?? .cpu
        return ProcessComparator(field: field, order: active.order)
    }

    static func field(for keyPath: PartialKeyPath<ProcessRow>) -> ProcessSortField? {
        switch keyPath {
        case \ProcessRow.name: .name
        case \ProcessRow.cpuFraction: .cpu
        case \ProcessRow.memoryBytes: .memory
        case \ProcessRow.pid: .pid
        case \ProcessRow.userName: .user
        case \ProcessRow.threadCount: .threads
        case \ProcessRow.cpuTimeSeconds: .cpuTime
        case \ProcessRow.diskReadBytes: .diskRead
        case \ProcessRow.diskWrittenBytes: .diskWrite
        default: nil
        }
    }
}
```

**Two integration notes the implementer needs:**

**1. The sort binding cannot be `[ProcessComparator]`.** `Table(_:sortOrder:)` types that array to whatever `TableColumn(_:value:)` produces, which is `KeyPathComparator<ProcessRow>`. That is why the binding holds key-path comparators for the header UI, and `resort()` translates to `ProcessComparator` — the only place ordering is actually decided. SwiftUI's own comparator would sort `nil` **first** ascending, which is the behaviour this whole design rejects, so nothing may be sorted by the bound comparator directly.

**2. The Architecture column binds `value: \.name` deliberately.** `ProcessArchitecture` is not `Comparable`, so it cannot be a sort key. Sorting by architecture is handled through `ProcessComparator`'s `.architecture` case, which compares the formatted strings. If a nicer binding is found, take it — but do not make `ProcessArchitecture` conform to `Comparable` just to satisfy a column, since there is no meaningful order between native and translated.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd VitalsCore && swift test --filter ProcessesPageTests`
Expected: PASS, 3 tests. Rendering needs a GUI session; the harness renders through an off-screen `NSWindow`.

- [ ] **Step 5: Commit**

```bash
git add VitalsCore/Sources/VitalsUI/Pages/Processes/ProcessesPage.swift VitalsCore/Tests/VitalsUITests/ProcessesPageTests.swift
git commit -m "feat: add the processes table page"
```

---

### Task 7: Wire it into the shell and measure the cadence

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/Shell/SidebarSection.swift`
- Modify: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`
- Test: `VitalsCore/Tests/VitalsUITests/PageConsistencyTests.swift` (already asserts the invariant — should now fail until this task lands)

**Interfaces:**
- Consumes: `ProcessesPage` from Task 6.

- [ ] **Step 1: Confirm the existing consistency test fails**

`PageConsistencyTests.implementedSectionsAreExactlyTheBuiltOnes` asserts that `SidebarSection.isImplemented` matches the set of pages that exist. `ProcessesPage` now exists but `.processes` still reports unimplemented.

Run: `cd VitalsCore && swift test --filter PageConsistencyTests`
Expected: PASS currently — the test compares `isImplemented` against a hardcoded set, so it will not notice on its own. Update that expected set first:

```swift
        #expect(implemented == Set([.overview, .processes, .cpu, .memory, .gpu, .storage, .network]))
```

Re-run. Expected: FAIL — `.processes` is missing from `isImplemented`.

Also extend the absence-wording test in the same file, so the table's vocabulary
is held to the other two rather than being free to drift:

```swift
    @Test("absence is worded the same way everywhere it appears")
    func absenceWordingIsConsistent() {
        #expect(StatRow.displayValue(nil) == "Unavailable")
        #expect(MetricTile.displayValue(nil) == "—")
        // Table cells use the em-dash form. A third vocabulary here would mean
        // the same fact reading three different ways in one app.
        #expect(ProcessRow.displayValue(nil) == MetricTile.displayValue(nil))
    }
```

Keep whatever the existing assertions in that test are; this adds one line to
them rather than replacing the test.

- [ ] **Step 2: Mark the section implemented**

In `VitalsCore/Sources/VitalsUI/Shell/SidebarSection.swift`:

```swift
    public var isImplemented: Bool {
        switch self {
        case .overview, .processes, .cpu, .memory, .gpu, .storage, .network: true
        default: false
        }
    }
```

- [ ] **Step 3: Route to the page**

In `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`, add an arm to `detail` above the `default`:

```swift
        case .processes:
            ProcessesPage(store: store)
```

- [ ] **Step 4: Run the full suite**

Run: `cd VitalsCore && swift test`
Expected: PASS, including `PageConsistencyTests` and `SidebarSectionTests`.

- [ ] **Step 5: Measure what the process cadence actually costs**

The design deferred the cadence decision to a measurement rather than a guess. `OverheadTests` already samples every series and prints a figure.

```bash
cd VitalsCore && swift test --filter OverheadTests
```

Record the printed overhead percentage in the report. Then measure the alternative: temporarily change `.processes` registration in `StandardSamplers.registerAll` from `cadence: .slow` to `cadence: .fast`, re-run `OverheadTests`, and record that figure too. **Restore `.slow` afterwards** — this step measures, it does not change the shipped cadence.

Report both numbers. A faster cadence ships only if a human decides the cost is worth it.

- [ ] **Step 6: Verify in the running app**

```bash
cd VitalsCore && swift run VitalsApp
```

Select Processes in the sidebar. Confirm: rows appear with real names; the heaviest process is at the top; `kernel_task` and other root-owned processes show an em dash in CPU rather than `0%`; typing in the filter narrows the list; clicking a column header re-sorts and unreadable rows stay at the bottom either way.

Capture the window (System Events window bounds plus `screencapture -R`, no Screen Recording permission needed) and **confirm via the accessibility API that Processes is the selected row before describing the screenshot** — an agent on this project once reported a screenshot that turned out to be a different page.

- [ ] **Step 7: Clean build check and commit**

```bash
cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning
```

Expected: `0`.

```bash
git add VitalsCore/Sources/VitalsUI/Shell VitalsCore/Tests/VitalsUITests/PageConsistencyTests.swift
git commit -m "feat: route the Processes sidebar entry to its page"
```

---

## Completion criteria

- Selecting Processes shows a live table of every running process.
- Unreadable values render as an em dash and sort last in both directions.
- Filtering narrows by name or exact pid; no match reads differently from no data.
- CPU and Memory cells carry heat shading scaled to the visible rows; unreadable cells carry none.
- Values refresh in place without the row order changing between sorts.
- Full suite green, clean build with zero warnings.

## What comes next

Each is its own slice, in rough order of value:

1. Context menu — Quit and Force Quit, with the confirmation and protected-process handling those need.
2. Apps / Background / System grouping, which needs a classification rule of its own.
3. The process tree, using `parentPID`, which is already sampled.
4. The inspector sheet: open files, ports, per-thread CPU, code signature, environment.
5. Columns that need the privileged helper (M3): per-process GPU, energy impact, network.
