import Foundation
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Overview tiles")
struct OverviewTilesTests {

    private func emptyStore() -> MetricsStore {
        MetricsStore(engine: MetricsEngine(), profile: nil)
    }

    /// The dropdown opens a row's page through `SidebarSection(rawValue:)`,
    /// so every tile id the Overview can show must name a page.
    @Test("every Overview tile id names a sidebar page")
    func tileIDsNamePages() {
        for id in OverviewPage.tileOrder(hasBattery: true) {
            #expect(SidebarSection(rawValue: id) != nil, "tile \(id) has no page")
        }
    }

    @Test("tiles are built in the order asked for, and an unknown id builds nothing")
    func tilesFollowRequestedOrder() {
        let store = emptyStore()
        let ids = OverviewPage.tileOrder(hasBattery: false)
        #expect(OverviewTiles.tiles(ids: ids, store: store).map(\.id) == ids)
        #expect(OverviewTiles.tile(id: "nonsense", store: store) == nil)
    }

    /// An empty store has measured nothing: every tile's value is absent,
    /// never a zero.
    @Test("an empty store builds tiles with no values, not zeros")
    func emptyStoreHasNoValues() {
        let tiles = OverviewTiles.tiles(ids: OverviewPage.tileOrder(hasBattery: true), store: emptyStore())
        #expect(tiles.allSatisfy { $0.value == nil })
        #expect(tiles.allSatisfy { $0.fraction == nil })
    }

    @Test("percent rounds to a whole number and refuses a non-finite fraction")
    func percentFormatting() {
        #expect(OverviewTiles.percent(0.234) == "23%")
        #expect(OverviewTiles.percent(0.235) == "24%")
        #expect(OverviewTiles.percent(1.0) == "100%")
        #expect(OverviewTiles.percent(.nan) == nil)
        #expect(OverviewTiles.percent(.infinity) == nil)
    }
}
