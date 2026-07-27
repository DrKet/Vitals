import MetricsEngine
import SwiftUI
import SystemMetrics
import Testing
@testable import VitalsUI

@MainActor
@Suite("GPU page")
struct GPUPageTests {

    private static func stamped(_ samples: [[GPUSample]]) -> [Timestamped<[GPUSample]>] {
        samples.enumerated().map { Timestamped(timestamp: 1000 + TimeInterval($0.offset), sample: $0.element) }
    }

    private static func sample(renderer: Double?, tiler: Double?) -> GPUSample {
        GPUSample(
            deviceUtilisation: 0.5, rendererUtilisation: renderer,
            tilerUtilisation: tiler, inUseMemoryBytes: nil, allocatedMemoryBytes: nil
        )
    }

    @Test("splits into the renderer and tiler bands the spec names")
    func splitsIntoEngineBands() {
        let history = Self.stamped([[Self.sample(renderer: 0.3, tiler: 0.2)]])
        let series = GPUPage.engineSeries(history: history)

        #expect(series.map(\.name) == ["Renderer", "Tiler"])
        #expect(series[0].values == [0.3])
        #expect(series[1].values == [0.2])
    }

    @Test("an engine the driver does not report is omitted, never drawn as a flat zero")
    func unreportedEngineIsOmitted() {
        // A 0% band would be a measurement this driver never made.
        let history = Self.stamped([[Self.sample(renderer: 0.3, tiler: nil)]])
        let series = GPUPage.engineSeries(history: history)

        #expect(series.map(\.name) == ["Renderer"])
    }

    @Test("one missing mid-history reading drops the whole band, rather than silently shortening it")
    func midHistoryGapDropsWholeBand() {
        // A single-tick history only ever exercises the `values.count ==
        // history.count` guard at count 1, which can't distinguish "drop the
        // whole band" from "just skip the missing tick and keep the rest" —
        // both happen to produce the same result when there is only one
        // tick. A three-tick history with the gap in the *middle* tells
        // them apart: if `engineSeries` merely skipped the nil and kept
        // going, `values.count` would be 2 against a `history.count` of 3,
        // silently misaligning the tiler band against its own timestamps.
        // The guard must instead drop the tiler band entirely.
        let history = Self.stamped([
            [Self.sample(renderer: 0.3, tiler: 0.1)],
            [Self.sample(renderer: 0.4, tiler: nil)],
            [Self.sample(renderer: 0.5, tiler: 0.2)],
        ])
        let series = GPUPage.engineSeries(history: history)

        #expect(series.map(\.name) == ["Renderer"])
        #expect(series[0].values.count == 3)
        #expect(abs(series[0].values[0] - 0.3) < 1e-9)
        #expect(abs(series[0].values[1] - 0.4) < 1e-9)
        #expect(abs(series[0].values[2] - 0.5) < 1e-9)
    }

    @Test("a driver reporting neither engine yields no bands at all")
    func noEnginesYieldsNoBands() {
        let history = Self.stamped([[Self.sample(renderer: nil, tiler: nil)]])
        #expect(GPUPage.engineSeries(history: history).isEmpty)
    }

    @Test("bands carry timestamps so gaps still break")
    func bandsCarryTimestamps() {
        let history = Self.stamped([
            [Self.sample(renderer: 0.3, tiler: 0.2)],
            [Self.sample(renderer: 0.4, tiler: 0.1)],
        ])
        #expect(GPUPage.engineSeries(history: history)[0].timestamps == [1000, 1001])
    }

    @Test("empty history yields no bands")
    func emptyHistoryYieldsNoBands() {
        #expect(GPUPage.engineSeries(history: []).isEmpty)
    }

    @Test("a single GPU is attributed, matching today's one-GPU-Mac behaviour")
    func singleGPUIsAttributed() {
        let gpu = GPUDevice(name: "Apple M2 Pro", topology: .unified(systemBytes: 17_179_869_184), coreCount: 16)
        // gpuCount: 1, sampleCount: 1 — the unambiguous case `device`
        // actually hits on every Apple Silicon Mac, one Metal device paired
        // with one IOAccelerator sample this tick. (A single-array
        // `isMultiGPU(_ gpus:)` convenience used to be asserted here
        // instead — removed along with the function itself, which a senior
        // review found dead in production; see `isMultiGPU(gpuCount:sampleCount:)`'s
        // doc comment.)
        #expect(GPUPage.isMultiGPU(gpuCount: 1, sampleCount: 1) == false)
        #expect(GPUPage.attributedDevice([gpu], sampleCount: 1) == gpu)
    }

    @Test("no reported GPU is unavailable, not ambiguous")
    func noGPUIsNotTreatedAsAmbiguous() {
        // gpuCount: 0, sampleCount: 0 — no sample either, an ordinary
        // absence rather than ambiguity (see `primaryValueGatedWithStats`'s
        // equivalent case).
        #expect(GPUPage.isMultiGPU(gpuCount: 0, sampleCount: 0) == false)
        #expect(GPUPage.attributedDevice([], sampleCount: 0) == nil)
    }

    @Test("more than one GPU is never attributed, since nothing correlates a Metal device with an IOAccelerator sample")
    func multipleGPUsAreNeverAttributed() {
        // `device` (Metal's `MTLCopyAllDevices()` order) and `latest` (IOKit's
        // iteration order) are independent enumerations with no shared
        // identifier. On a Mac with more than one GPU — an Intel iGPU plus a
        // discrete card, or an eGPU — naming this device while showing that
        // sample's numbers next to it would attribute a real measurement to
        // the wrong piece of hardware. The guard must refuse to name any
        // device at all in that case, rather than guess.
        let gpus = [
            GPUDevice(name: "Intel UHD Graphics 630", topology: .shared(maxSharedBytes: 1_536_000_000), coreCount: nil),
            GPUDevice(name: "AMD Radeon Pro 5500M", topology: .dedicated(vramBytes: 8_589_934_592), coreCount: nil),
        ]
        // gpuCount: 2, sampleCount: 1 — the direct case: two named GPUs, a
        // single IOAccelerator sample this tick.
        #expect(GPUPage.isMultiGPU(gpuCount: gpus.count, sampleCount: 1) == true)
        #expect(GPUPage.attributedDevice(gpus, sampleCount: 1) == nil)
    }

    @Test("attributedDevice also catches the mirror case: one named GPU but more than one IOAccelerator sample this tick")
    func attributedDeviceCatchesTheMirrorCaseToo() {
        // The case `GPUPage.device` must not silently miss: a single Metal
        // device paired with two IOAccelerator samples this tick is exactly
        // as unsafe to name as two Metal devices — see
        // `isMultiGPU(gpuCount:sampleCount:)`'s doc comment. Before this fix,
        // `device` computed this itself against the instance `isMultiGPU`
        // rather than calling `attributedDevice`, so this exact case was
        // never actually exercised through the function these assertions
        // guard.
        let gpu = GPUDevice(name: "Apple M2 Pro", topology: .unified(systemBytes: 17_179_869_184), coreCount: 16)
        #expect(GPUPage.attributedDevice([gpu], sampleCount: 2) == nil)
    }

    @Test("the mirror case is caught too: one named GPU but more than one IOAccelerator sample this tick")
    func mirrorCaseIsAlsoAmbiguous() {
        // Metal's own enumeration (`gpuCount`) reporting exactly one device
        // says nothing about what IOAccelerator handed back this tick — the
        // two are independent enumerations (see `GPUPage`'s doc comment) —
        // so a single named GPU paired with two IOAccelerator samples is
        // exactly as ambiguous as two named GPUs paired with one sample.
        #expect(GPUPage.isMultiGPU(gpuCount: 1, sampleCount: 2) == true)
        // And the already-covered direct case still holds through the general form.
        #expect(GPUPage.isMultiGPU(gpuCount: 2, sampleCount: 1) == true)
        // Only when both enumerations agree on exactly one device is naming safe.
        #expect(GPUPage.isMultiGPU(gpuCount: 1, sampleCount: 1) == false)
        #expect(GPUPage.isMultiGPU(gpuCount: 0, sampleCount: 0) == false)
    }

    @Test("the primary reading is withheld under the exact same ambiguity as the stat rows, including the mirror case")
    func primaryValueGatedWithStats() {
        let sample = Self.sample(renderer: 0.3, tiler: 0.2)

        // Two named GPUs, one IOAccelerator sample: the direct case.
        #expect(GPUPage.attributableLatest(sample, gpuCount: 2, sampleCount: 1) == nil)
        // One named GPU, two IOAccelerator samples: the mirror case fix 1 closes.
        #expect(GPUPage.attributableLatest(sample, gpuCount: 1, sampleCount: 2) == nil)
        // Unambiguous: the sample survives.
        #expect(GPUPage.attributableLatest(sample, gpuCount: 1, sampleCount: 1) == sample)
        #expect(GPUPage.attributableLatest(sample, gpuCount: 0, sampleCount: 1) == sample)
        // No sample at all is a separate, ordinary absence — not ambiguity.
        #expect(GPUPage.attributableLatest(nil, gpuCount: 1, sampleCount: 1) == nil)
    }

    @Test("the chart series is withheld under the same ambiguity, including the mirror case")
    func seriesGatedWithStats() {
        let history = Self.stamped([[Self.sample(renderer: 0.3, tiler: 0.2)]])
        let series = GPUPage.engineSeries(history: history)
        #expect(!series.isEmpty)

        // A chart labelled "Renderer"/"Tiler" drawn from an arbitrary sample
        // would contradict the stat rows reading "Unavailable" for the same
        // engines immediately below it — the inconsistency fix 1 closes.
        #expect(GPUPage.attributableSeries(series, gpuCount: 2, sampleCount: 1).isEmpty)
        #expect(GPUPage.attributableSeries(series, gpuCount: 1, sampleCount: 2).isEmpty)
        // Unambiguous: the series passes through unchanged.
        #expect(GPUPage.attributableSeries(series, gpuCount: 1, sampleCount: 1) == series)
    }

    @Test("each memory topology is described distinctly, never flattened")
    func memoryTopologiesAreDistinct() {
        // The three cases mean different things to a reader and must not read
        // identically.
        let unified = GPUPage.describeMemory(.unified(systemBytes: 17_179_869_184))
        let dedicated = GPUPage.describeMemory(.dedicated(vramBytes: 8_589_934_592))
        let shared = GPUPage.describeMemory(.shared(maxSharedBytes: 4_294_967_296))

        #expect(unified.contains("nified"))
        #expect(dedicated.contains("VRAM"))
        #expect(shared.contains("hared"))
        #expect(Set([unified, dedicated, shared]).count == 3)
    }

    /// The whole point of this test: nothing before it ever constructed a
    /// `GPUPage` from a `MetricsStore` and rendered it — every prior test in
    /// this file covers only static, pure helpers. Using this machine's real
    /// GPU inventory (`HardwareProfile.detect()`) also means this exercises
    /// exactly the single-GPU path fix 1 above must leave unchanged.
    @Test("renders a full page assembled from a live store, not just its pure helpers")
    func rendersFullPageFromStore() async throws {
        let profile = try HardwareProfile.detect()
        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler {
                [
                    // Renderer + Tiler sums to 0.9 — high enough that the
                    // stacked total's curve sits within the top ~10% of the
                    // chart's canvas regardless of how tall it actually
                    // renders. See `chartCanvasProbeRegion`'s doc comment.
                    GPUSample(
                        deviceUtilisation: 0.6, rendererUtilisation: 0.5, tilerUtilisation: 0.4,
                        inUseMemoryBytes: 2_000_000_000, allocatedMemoryBytes: 4_000_000_000
                    )
                ]
            },
            for: .gpu,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: profile)

        let task = Task { await store.stream(.gpu) }
        try await waitUntil { store.gpuHistory.count >= 2 }
        task.cancel()

        let rendered = try renderPNG(
            GPUPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "gpu-page-with-data"
        )
        // See `CPUPageTests.rendersFullPageFromStore` for why `fileExists`
        // alone was vacuous, and
        // `regionHasSaturatedColor(in:region:matchingHueOf:)`'s doc comment
        // for why matching only the non-lead band hues (never the page's own
        // accent) is what actually proves the chart itself painted here,
        // rather than merely something in the panel.
        let series = GPUPage.engineSeries(history: store.gpuHistory)
        let nonLeadHues = Array(Vitals.seriesColors(startingAt: Vitals.Palette.gpu, count: series.count).dropFirst().map(hue(of:)))
        #expect(try regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion, matchingHueOf: nonLeadHues))
    }

    /// Fix 3: `attributedDeviceCatchesTheMirrorCaseToo` above proves the pure
    /// `attributedDevice` function handles the mirror case — but nothing
    /// before this test ever rendered a real `GPUPage` while that ambiguity
    /// was live and confirmed what production actually does with it:
    /// withhold the primary value and chart (per
    /// `attributableLatest`/`attributableSeries`, gated on the same
    /// `isMultiGPU(gpuCount:sampleCount:)` rule) rather than show one
    /// arbitrarily-picked sample's numbers.
    ///
    /// This proves `attributableSeries`/`attributableLatest`'s own gating,
    /// not `device`'s — those three are gated independently of one another
    /// (`body` below computes each directly from `gpuCount`/`sampleCount`,
    /// not by reusing `device`). `device`'s own fixed wiring is what
    /// `deviceRoutesThroughAttributedDeviceWithRealSampleCount` right below
    /// this test exercises directly — a pixel probe over the chart region
    /// couldn't catch a regression there, since `device` only ever reaches
    /// the header's vendor name and the "Memory" stat's text, neither of
    /// which this harness can read.
    ///
    /// Works on a single-GPU machine — every machine this suite is likely to
    /// run on, including this one: the ambiguity here comes entirely from
    /// the *mirror* case, a real single-GPU `HardwareProfile` paired with a
    /// sampler that (implausibly, but validly — IOAccelerator and Metal are
    /// independent enumerations, see this file's top-level doc comment)
    /// reports two `GPUSample`s in one tick. No actual multi-GPU hardware is
    /// needed to exercise it.
    @Test("a page in the ambiguous multi-GPU state withholds its chart, rendered from a live store")
    func rendersWithheldStateForAmbiguousGPUSamples() async throws {
        let profile = try HardwareProfile.detect()
        try #require(
            profile.gpus.count == 1,
            "this test's ambiguity comes from the sample mirror case, not real multi-GPU hardware"
        )

        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler {
                // Two samples this tick from a Mac Metal reports only one
                // GPU for — the mirror case
                // `isMultiGPU(gpuCount:sampleCount:)` exists to catch.
                //
                // Built inline rather than via `Self.sample(renderer:tiler:)`:
                // this closure is `@Sendable` and non-isolated (see
                // `AnySampler`'s initializer), while `Self.sample` inherits
                // this suite's `@MainActor` isolation — calling it from here
                // is exactly the actor-isolation violation the established
                // pattern in `CPUPageTests.rendersFullPageFromStore` and
                // `MemoryPageTests.rendersFullPageFromStore` avoids the same
                // way.
                [
                    GPUSample(
                        deviceUtilisation: 0.5, rendererUtilisation: 0.4,
                        tilerUtilisation: 0.3, inUseMemoryBytes: nil, allocatedMemoryBytes: nil
                    ),
                    GPUSample(
                        deviceUtilisation: 0.5, rendererUtilisation: 0.5,
                        tilerUtilisation: 0.4, inUseMemoryBytes: nil, allocatedMemoryBytes: nil
                    ),
                ]
            },
            for: .gpu,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: profile)

        let task = Task { await store.stream(.gpu) }
        try await waitUntil { (store.gpu?.count ?? 0) == 2 }
        task.cancel()

        let rendered = try renderPNG(
            GPUPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "gpu-page-ambiguous-multi-gpu"
        )
        // The chart must stay withheld, not merely still work by
        // coincidence — `attributableSeries` gates it on the exact same
        // ambiguity rule `device` is gated on too, independently.
        #expect(try !regionHasSaturatedColor(in: rendered, region: chartCanvasProbeRegion))
    }

    /// Fix 3, the other half: `rendersWithheldStateForAmbiguousGPUSamples`
    /// above proves `attributableSeries`/`attributableLatest` withhold the
    /// chart on the mirror case, but `device` is gated independently of
    /// those two — nothing in `body` derives one from the other — so that
    /// test cannot catch a regression specific to `device`'s own wiring.
    ///
    /// This is exactly the regression a senior review found by hand: a
    /// version of `device` that computed the mirror-case check inline
    /// against the instance `isMultiGPU` (correct, but not exercised through
    /// `attributedDevice`) is indistinguishable from a version that silently
    /// stopped checking `sampleCount` altogether — both keep every existing
    /// assertion on the *pure* `attributedDevice` function green, since
    /// nothing called it from production either way. Constructing a real
    /// `GPUPage` and reading its `device` property directly (internal for
    /// exactly this reason, per its own doc comment) is what closes that
    /// gap: it fails if `device` stops forwarding the real
    /// `store.gpu?.count` into `attributedDevice`, which a pixel probe over
    /// the chart region cannot detect, since `device` never reaches the
    /// chart — only the header's vendor name and the "Memory" stat.
    ///
    /// Verified by hand: temporarily reverting `device` to pass a hardcoded
    /// `sampleCount: 0` instead of `store.gpu?.count ?? 0` — the exact bug
    /// this fix closes — left `rendersWithheldStateForAmbiguousGPUSamples`
    /// still passing (it does not exercise `device` at all) while this test
    /// failed, naming the lone Metal device instead of withholding it.
    @Test("device forwards the real sample count into attributedDevice, catching the mirror case in what production actually runs")
    func deviceRoutesThroughAttributedDeviceWithRealSampleCount() async throws {
        let profile = try HardwareProfile.detect()
        try #require(
            profile.gpus.count == 1,
            "this test's ambiguity comes from the sample mirror case, not real multi-GPU hardware"
        )

        let engine = MetricsEngine(intervalOverride: .milliseconds(5))
        await engine.register(
            AnySampler {
                // Two samples this tick from a Mac Metal reports only one GPU
                // for — see `rendersWithheldStateForAmbiguousGPUSamples` for
                // why this is built inline rather than via `Self.sample`.
                [
                    GPUSample(
                        deviceUtilisation: 0.5, rendererUtilisation: 0.4,
                        tilerUtilisation: 0.3, inUseMemoryBytes: nil, allocatedMemoryBytes: nil
                    ),
                    GPUSample(
                        deviceUtilisation: 0.5, rendererUtilisation: 0.5,
                        tilerUtilisation: 0.4, inUseMemoryBytes: nil, allocatedMemoryBytes: nil
                    ),
                ]
            },
            for: .gpu,
            cadence: .fast
        )
        let store = MetricsStore(engine: engine, profile: profile)

        let task = Task { await store.stream(.gpu) }
        try await waitUntil { (store.gpu?.count ?? 0) == 2 }
        task.cancel()

        #expect(GPUPage(store: store).device == nil)
    }

    @Test("a freshly constructed page with no samples yet still renders, rather than crashing on nil state")
    func rendersFromEmptyStore() throws {
        let store = MetricsStore(engine: MetricsEngine(), profile: nil)
        let rendered = try renderPNG(
            GPUPage(store: store),
            size: CGSize(width: 800, height: 700),
            named: "gpu-page-empty-store"
        )
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
    }
}
