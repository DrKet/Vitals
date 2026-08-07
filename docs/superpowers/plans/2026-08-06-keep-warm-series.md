# Keep-warm fast series Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the five cheap fast chart series sampling for the whole session so switching to a hardware page shows a full graph immediately instead of refilling over a second or two.

**Architecture:** `MetricsStore` gains a named `keepWarmSeries` set and a `keepWarm()` that subscribes to all of them concurrently until cancelled; `AppShell` calls it once from the root view. Overlap with a page's own subscription is harmless because `MetricsStore.apply` is already idempotent on the sample timestamp.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency), SwiftUI, Swift Testing (`@Test`/`@Suite`/`#expect`), macOS 26 floor. `MetricsStore` is `@Observable @MainActor final class`; `MetricsEngine` is an `actor`.

## Global Constraints

- **Warm set is exactly `[.cpu, .memory, .gpu, .network, .diskIO]`.** Deliberately excludes `.processes` (walks the whole process table — the expensive series the subscription-driven design exists to keep off an idle machine), `.sensors` and `.battery` (5-second slow cadence), and `.storage` (no chart, live field never expires).
- **Always warm while the app runs.** No Low Power Mode / occlusion backoff in this version.
- **Nothing else changes** — not samplers, cadences, charts, or staleness rules.
- **Swift 6 language mode, strict concurrency, macOS 26.0 floor.**
- **`swift test --filter` matches TYPE identifiers** (e.g. `MetricsStoreTests`), not `@Suite` display names.
- **Warning check needs a clean build:** `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` must print `0`.
- **Build/test:** `cd VitalsCore && swift build` / `swift test` / `swift test --filter <TypeName>`.

---

### Task 1: `keepWarmSeries` + `keepWarm()`, wired into `AppShell`

**Files:**
- Modify: `VitalsCore/Sources/VitalsUI/MetricsStore.swift` (add the static set and the method; `stream(_:)` already exists on this type)
- Modify: `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift` (one `.task` on the root view)
- Test: `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `MetricsStore.stream(_ key: SeriesKey) async` (existing); `MetricsEngine.activeSeries: Set<SeriesKey>` (existing, `await`ed — it is an actor property); `SeriesKey` (`Sendable, Hashable, CaseIterable`); the test helper `waitUntilAsync { await ... }` and `AnySampler { ... }` (existing in the suite).
- Produces: `MetricsStore.keepWarmSeries: Set<SeriesKey>` (static) and `MetricsStore.keepWarm() async`.

- [ ] **Step 1: Write the failing tests**

Add to `VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift`, inside its `@Suite` struct:

```swift
@Test("the keep-warm set holds the cheap fast series and excludes the costly ones")
func keepWarmSetExcludesCostlySeries() {
    let warm = MetricsStore.keepWarmSeries
    #expect(warm == [.cpu, .memory, .gpu, .network, .diskIO])
    // The load-bearing exclusions — the whole point is to never warm these:
    // .processes walks the process table (the expensive series the
    // subscription-driven design keeps off an idle machine), .sensors and
    // .battery are the 5s slow cadence, and .storage has no chart to fill.
    #expect(!warm.contains(.processes))
    #expect(!warm.contains(.sensors))
    #expect(!warm.contains(.battery))
    #expect(!warm.contains(.storage))
}

@Test("keepWarm keeps the whole warm set sampling with no page subscribed")
func keepWarmSustainsSamplingWithNoPage() async throws {
    let engine = MetricsEngine(intervalOverride: .milliseconds(5))
    // Register a sampler for each warm series so a subscription starts real
    // sampling. The payload type is irrelevant here — this test asserts the
    // engine is actively sampling (activeSeries), not what the store parses.
    for key in MetricsStore.keepWarmSeries {
        await engine.register(AnySampler { 0 }, for: key, cadence: .fast)
    }
    let store = MetricsStore(engine: engine, profile: nil)

    // No page is subscribed; keepWarm alone must drive the engine.
    let task = Task { await store.keepWarm() }
    try await waitUntilAsync {
        await engine.activeSeries.isSuperset(of: MetricsStore.keepWarmSeries)
    }
    #expect(await engine.activeSeries.isSuperset(of: MetricsStore.keepWarmSeries))
    task.cancel()
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: FAIL to compile — `MetricsStore.keepWarmSeries` and `keepWarm()` do not exist.

- [ ] **Step 3: Implement `keepWarmSeries` and `keepWarm()`**

In `VitalsCore/Sources/VitalsUI/MetricsStore.swift`, add these to the `MetricsStore` class (place them near `stream(_:)`):

```swift
    /// The series kept sampling for the whole session, regardless of which
    /// page is visible, so switching to their charts is instant instead of
    /// refilling. Only the cheap 1 Hz chart series belong here.
    ///
    /// Excludes `.processes` (walks the whole process table — the expensive
    /// series subscription-driven sampling exists to keep off an idle
    /// machine), `.sensors` and `.battery` (5-second cadence, little to gain),
    /// and `.storage` (no chart, and its live field never expires).
    public static let keepWarmSeries: Set<SeriesKey> = [.cpu, .memory, .gpu, .network, .diskIO]

    /// Subscribes to every series in `keepWarmSeries` and keeps them sampling
    /// until cancelled. Call once from the app's root view; the subscriptions
    /// then live for the whole session.
    ///
    /// Each child runs `stream(_:)`, which loops until its subscription ends,
    /// so this never returns on its own — cancelling the caller cancels the
    /// group, which tears every warm subscription down. Running alongside a
    /// page's own `stream(_:)` for the same series is harmless: `apply` is
    /// idempotent on the sample timestamp, so a tick fanned out to both
    /// subscribers is stored once.
    public func keepWarm() async {
        await withTaskGroup(of: Void.self) { group in
            for key in Self.keepWarmSeries {
                group.addTask { await self.stream(key) }
            }
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd VitalsCore && swift test --filter MetricsStoreTests`
Expected: PASS (both new tests and the pre-existing ones).

- [ ] **Step 5: Mutation-check both tests**

Confirm each test is load-bearing, then restore.

- Temporarily add `.processes` to the set: `[.cpu, .memory, .gpu, .network, .diskIO, .processes]`. Run `swift test --filter MetricsStoreTests` → `keepWarmSetExcludesCostlySeries` FAILS (both the `==` and `!contains(.processes)`). Restore.
- Temporarily make `keepWarm()` a no-op (`public func keepWarm() async {}`). Run → `keepWarmSustainsSamplingWithNoPage` FAILS: `waitUntilAsync` never sees the warm set active and times out. Restore the real implementation and re-run → green.

- [ ] **Step 6: Wire it into `AppShell`**

In `VitalsCore/Sources/VitalsUI/Shell/AppShell.swift`, add one modifier to the `NavigationSplitView` — immediately after the `} detail: { ... }` closing brace of the split view, before the closing brace of `body`:

```swift
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Vitals.Metrics.contentPadding)
        }
        // Keep the cheap fast chart series sampling for the whole session so
        // switching to a hardware page shows a full graph immediately. The
        // root view lives as long as the window, so this subscription does
        // too; a page's own `.task { stream(_:) }` running alongside it is
        // deduplicated by `MetricsStore.apply`. See `keepWarm()`.
        .task { await store.keepWarm() }
    }
```

- [ ] **Step 7: Clean build and full suite**

Run: `cd VitalsCore && rm -rf .build && swift build --build-tests 2>&1 | grep -ci warning` → expect `0`.
Run: `cd VitalsCore && swift test` → expect all pass. (The load-sensitive `MetricsStoreTests` `waitUntil` timeouts are the known machine-load flakiness — if 1–2 appear, re-run once; the new tests use the same `intervalOverride: .milliseconds(5)` fast path as their neighbours.)

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/Vitals
git add VitalsCore/Sources/VitalsUI/MetricsStore.swift \
        VitalsCore/Sources/VitalsUI/Shell/AppShell.swift \
        VitalsCore/Tests/VitalsUITests/MetricsStoreTests.swift
git commit -m "feat: keep the fast chart series warm for the session

Subscription-driven sampling stops a series the moment its page closes, so
switching to a hardware page refilled its chart over a second or two. keepWarm
subscribes to the five cheap fast series (cpu, memory, gpu, network, diskIO)
for the app's lifetime from the root view, so those switches are instant.
Excludes the process table and the slow-cadence series deliberately; apply's
timestamp idempotency makes the overlap with a page's own stream a no-op."
```

---

## Notes for the implementer

- **`keepWarm()` never returns** — do not `await` it expecting completion. Tests and `AppShell` both run it in a task/`.task` and rely on cancellation to stop it (exactly as they do for `stream`). The existing test "cancelling the streaming task releases the engine subscription" proves cancellation propagates to `stream`; in the group it propagates to all children.
- **`engine.activeSeries` needs the series registered** — `attach` finishes the continuation for an unregistered key without starting a task, so the Step-1 test registers a sampler for every warm series. `AnySampler { 0 }` is enough; the payload type is irrelevant because the assertion is on `activeSeries`, not store state.
- **No stored property is added to a `SystemMetrics` struct**, so the incremental-build SIGSEGV trap does not apply — but Step 7's clean build is still required for the warning check and the GUI-session suite.
- **Do not** add power-aware backoff, warm Sensors, or touch cadences/charts/staleness — all explicitly out of scope.
