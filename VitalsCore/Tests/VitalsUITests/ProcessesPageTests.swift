import AppKit
import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Processes page")
struct ProcessesPageTests {

    private static nonisolated func snapshot(_ pid: pid_t, _ name: String, cpuTime: Double?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: 1, name: name, userID: 501,
            memoryFootprintBytes: UInt64(pid) * 1_000_000, cpuTimeSeconds: cpuTime,
            threadCount: 3, diskBytesRead: 512, diskBytesWritten: 256,
            architecture: .native
        )
    }

    /// The fixture every render test in this file shares: three processes
    /// whose CPU fractions are deliberately spread so the default sort's
    /// result is unambiguous — Xcode is the only one with a CPU heat strong
    /// enough to register as a saturated pixel, launchd's is real but too
    /// faint to paint any colour, and kernel_task's is unreadable outright.
    private static nonisolated func processSample() -> ProcessSeriesSample {
        ProcessSeriesSample(
            processes: [
                Self.snapshot(1, "launchd", cpuTime: 12),
                Self.snapshot(42, "Xcode", cpuTime: 900),
                Self.snapshot(77, "kernel_task", cpuTime: nil),
            ],
            cpuUsage: [1: 0.02, 42: 3.5]      // 77 deliberately unreadable
        )
    }

    private func storeWithProcesses() async throws -> MetricsStore {
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { Self.processSample() }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)
        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()
        return store
    }

    /// Hosts `ProcessesPage(store:)` in a live, real `NSHostingView`/`NSWindow`
    /// — the same technique `RenderHarness.renderPNG` uses internally — but
    /// keeps the hosting view alive and returns it rather than capturing
    /// immediately, so a caller can mutate `store` and force further layout
    /// passes on the SAME view instance before ever taking a screenshot.
    /// `renderPNG` cannot do this: it constructs, lays out and captures a
    /// view in one call, so it can only ever exercise a page's
    /// "already populated at construction" path — every render test in this
    /// file that does NOT need to observe a state transition uses it, but a
    /// test of that transition itself (Fix 1's whole subject) needs this.
    @MainActor
    private func hostLive(store: MetricsStore, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        let content = AnyView(
            ProcessesPage(store: store)
                .environment(\.vitalsGlassEnabled, false)
                .frame(width: size.width, height: size.height)
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (hosting, window)
    }

    /// Forces one more layout/display pass on an already-hosted view (so a
    /// state change made since the last capture is reflected) and captures
    /// it, mirroring `RenderHarness.renderPNG`'s own bitmap-capture tail.
    @MainActor
    private func captureLive(
        _ hosting: NSHostingView<AnyView>, size: CGSize, named name: String
    ) throws -> RenderedImage {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            "could not create a bitmap rep for \(name)"
        )
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/vitals-render")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        return RenderedImage(url: url, scale: scale)
    }

    /// Where the CPU column's heat cell paints, for the top row and the third
    /// (last) row, in this file's fixture rendered at `900x600`.
    ///
    /// Derived empirically, not guessed: instrumenting the rendered
    /// `NSHostingView`'s live `NSTableView` (`rect(ofRow:)`/`rect(ofColumn:)`)
    /// against this exact fixture gave column bounds of x ∈ [169,310]pt for
    /// CPU and row bounds of y ∈ [61,85]pt / [109,133]pt for rows 0 and 2: the
    /// `Table` local coordinate origin sits at root `(20, 56)pt`, row height is
    /// `24pt`, and the CPU column spans local x ∈ [149,290]. Cross-checked
    /// against which pixels the render actually paints a saturated colour at:
    /// scanning `processes-page-with-data.png` finds exactly two saturated
    /// bands, y ∈ [93,108.5]pt (which also carries CPU-column colour — the
    /// only row that does, since only Xcode's 3.5 CPU fraction produces
    /// visible heat) and y ∈ [141,156.5]pt (Memory column only, at roughly
    /// twice the first band's intensity — consistent with kernel_task's
    /// memory heat of 1.0 against Xcode's 0.545, not launchd's, whose 0.013
    /// memory heat and 0.006 CPU heat are both too faint to register at all).
    /// That absence is itself confirmation launchd sits in the untouched
    /// middle row, exactly where CPU-descending-with-unknowns-last puts it.
    /// Insets stay clear of the heat cell's rounded-rect antialiased edges.
    private static let topRowCPUCell = CGRect(x: 180, y: 96, width: 115, height: 10)
    private static let thirdRowCPUCell = CGRect(x: 180, y: 145, width: 115, height: 10)

    /// The Memory column's heat cell for the top row, same derivation as
    /// `topRowCPUCell` above but at the Memory column's measured x-bounds
    /// (x ∈ [318,441.5]pt).
    private static let topRowMemoryCell = CGRect(x: 322, y: 96, width: 115, height: 10)

    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFromLiveStore() async throws {
        let store = try await storeWithProcesses()
        let rendered = try renderPNG(
            ProcessesPage(store: store),
            size: CGSize(width: 900, height: 600),
            named: "processes-page-with-data"
        )

        // The milestone's central rule, asserted where it actually matters —
        // on the assembled page, not just `ProcessTable.heatFraction` in
        // isolation: Xcode (readable, heaviest) gets CPU-accent shading in its
        // CPU cell, and kernel_task (unreadable CPU, sorted to the bottom row
        // by the default sort) gets NONE at all. `regionHasContent` would not
        // do here — it only proves *something* differs from the corner
        // background, which a plain cell border or row separator would
        // already satisfy regardless of heat. Only a saturated-colour probe
        // can tell "shaded" from "not shaded," since every neutral-grey part
        // of this page (text, row lines, the table's own material) is
        // deliberately colourless.
        #expect(try regionHasSaturatedColor(
            in: rendered, region: Self.topRowCPUCell, matchingHueOf: [hue(of: Vitals.Palette.cpu)]
        ))
        #expect(try regionHasSaturatedColor(in: rendered, region: Self.thirdRowCPUCell) == false)

        // Memory owns its own hue (`Vitals.Palette.memory`), distinct from
        // CPU's — the same way each hardware page owns a hue elsewhere in
        // this app. Matching specifically against the memory hue (not just
        // "any saturated colour") is what would catch a regression back to
        // both columns sharing `Vitals.Palette.cpu`.
        #expect(try regionHasSaturatedColor(
            in: rendered, region: Self.topRowMemoryCell, matchingHueOf: [hue(of: Vitals.Palette.memory)]
        ))
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
            named: "processes-page-empty-store"
        )

        // `renderPNG`'s own blank check is satisfied by the filter field's
        // border alone, so it would pass even if `content()` painted nothing
        // at all for a nil store. Pinning the filter field's OWN frame (not
        // "the image isn't blank") is a real, page-specific signal: it fails
        // if `header` — filter field included — is ever dropped or the
        // TextField stops rendering where the layout puts it. (`Text` in this
        // harness renders invisible white-on-white under Dark Mode — see
        // `RenderHarness.swift` and every other page's tests — so the actual
        // "No process listing available." wording cannot be pixel-tested
        // here; that limitation predates this page and is not this test's to
        // fix.) The negative half closes the other realistic regression: this
        // page's only saturated colour source is `heatCell`, which exists
        // only inside `table(rows:...)` — so a `content()` that showed the
        // table branch even for a nil store (rather than the message) would
        // paint colour nowhere real data does, and this would still catch
        // nothing painting, matching the true empty state.
        #expect(try regionHasContent(in: rendered, region: CGRect(x: 680, y: 20, width: 200, height: 24)))
        #expect(try regionHasSaturatedColor(in: rendered, region: CGRect(x: 0, y: 0, width: 900, height: 600)) == false)
    }

    @Test("""
        a listing that arrives after the page is already on screen still applies the default order itself — \
        CPU descending, unreadable last — without waiting for a header click
        """)
    func appliesDefaultOrderOnFirstArrival() async throws {
        // The regression Fix 1 closes: every other render test in this file
        // populates `store.processes` BEFORE constructing `ProcessesPage`,
        // which made them pass even when nothing re-ran `resort()` after a
        // cold `onAppear` no-op. This test builds the page while
        // `store.processes` is still nil — the page's actual first frame in
        // the running app — keeps that SAME hosted view instance alive, and
        // only then lets the sample land, exactly reproducing the timing the
        // bug depended on.
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(AnySampler { Self.processSample() }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)
        #expect(store.processes == nil)

        let size = CGSize(width: 900, height: 600)
        let (hosting, window) = hostLive(store: store, size: size)
        defer { window.orderOut(nil) }

        let task = Task { await store.stream(.processes) }
        try await waitUntil { store.processes != nil }
        task.cancel()
        // The listing has now landed on the SAME live page instance. Without
        // Fix 1, nothing here re-runs `resort()`, and `displayOrder` stays
        // permanently empty for this instance's remaining lifetime.
        let rendered = try captureLive(hosting, size: size, named: "processes-page-first-arrival")

        #expect(try regionHasSaturatedColor(
            in: rendered, region: Self.topRowCPUCell, matchingHueOf: [hue(of: Vitals.Palette.cpu)]
        ))
        #expect(try regionHasSaturatedColor(in: rendered, region: Self.thirdRowCPUCell) == false)
    }

    @Test("""
        the default order comes from the first sample that can actually tell processes apart by CPU, \
        not the necessarily CPU-blind bootstrap tick every cold engine delivers first
        """)
    func defaultOrderWaitsForSampleThatCanDifferentiateByCPU() async throws {
        // Found only by running the real app against a live engine, not by
        // reasoning about this file's synthetic fixtures: `ProcessCPUTracker`
        // (`SystemMetrics/Processes/ProcessInfo.swift`) computes a process'
        // CPU fraction as a delta against the PREVIOUS sample, so the very
        // FIRST `ProcessSeriesSample` a cold engine ever produces has an
        // entirely empty `cpuUsage` — nothing to diff against yet. A version
        // of Fix 1 keyed only on "has a sample arrived" (`store.processes ==
        // nil`) locks `displayOrder` in from that first, structurally
        // cpu-blind tick: sorting a column where every value ties is a
        // stable no-op, indistinguishable from never sorting at all — the
        // exact bug this milestone exists to fix, just one tick later than
        // the naive check catches it. This fixture reproduces that shape
        // directly: tick one mirrors the tracker's real bootstrap behaviour
        // (empty `cpuUsage`), tick two is this file's normal, differentiable
        // fixture.
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        let tickCount = SamplerState(0)
        await engine.register(AnySampler {
            let tick = tickCount.withLock { count -> Int in
                count += 1
                return count
            }
            guard tick > 1 else {
                return ProcessSeriesSample(
                    processes: [
                        Self.snapshot(1, "launchd", cpuTime: 12),
                        Self.snapshot(42, "Xcode", cpuTime: 900),
                        Self.snapshot(77, "kernel_task", cpuTime: nil),
                    ],
                    cpuUsage: [:]   // the bootstrap tick: nothing readable yet
                )
            }
            return Self.processSample()
        }, for: .processes, cadence: .slow)
        let store = MetricsStore(engine: engine, profile: nil)

        let size = CGSize(width: 900, height: 600)
        let (hosting, window) = hostLive(store: store, size: size)
        defer { window.orderOut(nil) }

        let task = Task { await store.stream(.processes) }
        // Wait past the bootstrap tick specifically, not just "any sample":
        // stopping at `store.processes != nil` would catch tick one, whose
        // `cpuUsage` is empty by construction, and prove nothing about
        // whether the page recovers once real data shows up.
        try await waitUntil { store.processes?.cpuUsage.isEmpty == false }
        task.cancel()
        let rendered = try captureLive(hosting, size: size, named: "processes-page-post-bootstrap-arrival")

        #expect(try regionHasSaturatedColor(
            in: rendered, region: Self.topRowCPUCell, matchingHueOf: [hue(of: Vitals.Palette.cpu)]
        ))
        #expect(try regionHasSaturatedColor(in: rendered, region: Self.thirdRowCPUCell) == false)
    }

    // MARK: Header key path -> sort field mapping

    /// `resort()` only ever reads `.keyPath` and `.order` off the bound
    /// `KeyPathComparator` — the actual ordering always goes through
    /// `ProcessComparator`. That makes this mapping table the single point of
    /// truth for which header a click on "Memory," "Threads," "Disk Write"
    /// etc. actually sorts by. `defaultSortIsCPUDescending` only exercises the
    /// `.cpu` branch; a swapped case here (e.g. diskRead/diskWrite) would
    /// silently sort the wrong column and nothing else would catch it.
    @Test("each sortable column's key path maps back to its own field, not a neighbour's")
    func keyPathMapsToExpectedField() {
        #expect(ProcessesPage.field(for: \ProcessRow.name) == .name)
        #expect(ProcessesPage.field(for: \ProcessRow.cpuFractionKey) == .cpu)
        #expect(ProcessesPage.field(for: \ProcessRow.memoryBytesKey) == .memory)
        #expect(ProcessesPage.field(for: \ProcessRow.pid) == .pid)
        #expect(ProcessesPage.field(for: \ProcessRow.userName) == .user)
        #expect(ProcessesPage.field(for: \ProcessRow.threadCountKey) == .threads)
        #expect(ProcessesPage.field(for: \ProcessRow.cpuTimeSecondsKey) == .cpuTime)
        #expect(ProcessesPage.field(for: \ProcessRow.diskReadBytesKey) == .diskRead)
        #expect(ProcessesPage.field(for: \ProcessRow.diskWrittenBytesKey) == .diskWrite)
        // Regression guard for the bug this key path exists to fix: the
        // Architecture column used to bind `\.name`, so a click silently
        // sorted by process name instead — same key path as the Process
        // column, so their sort indicators were indistinguishable too.
        #expect(ProcessesPage.field(for: \ProcessRow.architectureKey) == .architecture)
    }

    @Test("an unrecognised key path yields nil, which resort() falls back to CPU for")
    func unrecognisedKeyPathYieldsNil() {
        // The Architecture column binds its own `\.architectureKey` (a plain
        // `String`, distinct from `\.name`), so it is not a genuine
        // "unrecognised" case either. A raw, un-keyed property like
        // `\.cpuFraction` (as opposed to its `.cpuFractionKey` wrapper) is
        // never produced by any column and stands in for one here.
        #expect(ProcessesPage.field(for: \ProcessRow.cpuFraction) == nil)
    }
}
