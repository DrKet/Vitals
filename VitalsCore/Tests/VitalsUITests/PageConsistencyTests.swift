import Testing
@testable import VitalsUI

/// `@MainActor` because `MetricTile` and `StatRow` are SwiftUI `View`s and
/// therefore main-actor isolated; calling their static helpers from a
/// nonisolated test emits an actor-isolation warning, same as
/// `StatRowTests`/`MetricTileTests` already work around. The brief's literal
/// listing omits this — a verbatim copy warns under strict concurrency.
@MainActor
@Suite("Page consistency")
struct PageConsistencyTests {

    @Test("exactly the pages this plan builds are marked implemented")
    func implementedSectionsAreExactlyTheBuiltOnes() {
        // Pins the expected set so adding a page without marking it — or
        // marking one that was never built — fails here. Whether each is
        // actually *routed* in AppShell is checked visually in Task 8 Step 3;
        // a switch statement's arms are not introspectable from a test.
        let implemented = SidebarSection.allCases.filter(\.isImplemented)
        #expect(Set(implemented) == Set([.overview, .processes, .cpu, .memory, .gpu, .storage, .network, .sensors, .battery]))
    }

    @Test("each page uses a distinct disclosure key")
    func disclosureKeysAreDistinct() {
        // Reads the pages' own keys, not a copy of them — a test over a literal
        // array would be true by construction and would never notice two pages
        // actually sharing a key, which would make expanding one page's
        // specifications expand every other page's too.
        let keys = [
            CPUPage.disclosureKey,
            MemoryPage.disclosureKey,
            GPUPage.disclosureKey,
            StoragePage.disclosureKey,
            NetworkPage.disclosureKey,
            SensorsPage.disclosureKey,
            BatteryPage.disclosureKey,
        ]
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.isEmpty == false })
    }

    @Test("absence is worded consistently across components")
    func absenceWordingIsConsistent() {
        // Large readouts use an em dash, label/value rows use "Unavailable".
        // Two words for one idea would read as two different states.
        #expect(MetricTile.displayValue(nil) == "—")
        #expect(StatRow.displayValue(nil) == "Unavailable")
    }
}
