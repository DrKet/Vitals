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
        #expect(GPUPage.isMultiGPU([gpu]) == false)
        #expect(GPUPage.attributedDevice([gpu]) == gpu)
    }

    @Test("no reported GPU is unavailable, not ambiguous")
    func noGPUIsNotTreatedAsAmbiguous() {
        #expect(GPUPage.isMultiGPU([]) == false)
        #expect(GPUPage.attributedDevice([]) == nil)
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
        #expect(GPUPage.isMultiGPU(gpus) == true)
        #expect(GPUPage.attributedDevice(gpus) == nil)
    }

    @Test("the mirror case is caught too: one named GPU but more than one IOAccelerator sample this tick")
    func mirrorCaseIsAlsoAmbiguous() {
        // `isMultiGPU(_ gpus:)` only ever sees Metal's enumeration. Metal
        // reporting exactly one device says nothing about what IOAccelerator
        // handed back this tick — the two are independent enumerations (see
        // `GPUPage`'s doc comment) — so a single named GPU paired with two
        // IOAccelerator samples is exactly as ambiguous as two named GPUs
        // paired with one sample.
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
                    GPUSample(
                        deviceUtilisation: 0.6, rendererUtilisation: 0.5, tilerUtilisation: 0.2,
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
        #expect(FileManager.default.fileExists(atPath: rendered.url.path))
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
