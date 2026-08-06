import CoreGraphics
import Testing
@testable import VitalsUI

@Suite("Tile layout")
struct TileLayoutTests {

    // MARK: Column count

    @Test("a narrow container still gets one column rather than zero")
    func narrowContainerGetsOneColumn() {
        #expect(TileLayout.columnCount(width: 100, minimumTileWidth: 240, spacing: 12) == 1)
    }

    @Test("two tiles fit when the width allows both plus the gap")
    func twoTilesFit() {
        // 240 + 12 + 240 = 492
        #expect(TileLayout.columnCount(width: 492, minimumTileWidth: 240, spacing: 12) == 2)
    }

    @Test("one pixel short of two tiles yields one column")
    func justUnderTwoTilesYieldsOne() {
        #expect(TileLayout.columnCount(width: 491, minimumTileWidth: 240, spacing: 12) == 1)
    }

    @Test("spacing is counted between tiles, not after the last one")
    func spacingIsBetweenOnly() {
        // Three tiles need 240*3 + 12*2 = 744. If spacing were counted after
        // every tile, 744 would only fit two.
        #expect(TileLayout.columnCount(width: 744, minimumTileWidth: 240, spacing: 12) == 3)
    }

    @Test("a zero or negative width does not produce a zero or negative column count")
    func degenerateWidthIsSafe() {
        #expect(TileLayout.columnCount(width: 0, minimumTileWidth: 240, spacing: 12) == 1)
        #expect(TileLayout.columnCount(width: -50, minimumTileWidth: 240, spacing: 12) == 1)
    }

    @Test("a zero minimum tile width does not divide by zero")
    func zeroMinimumIsSafe() {
        #expect(TileLayout.columnCount(width: 500, minimumTileWidth: 0, spacing: 12) == 1)
    }

    @Test("the column count is capped when a maximum is given")
    func maximumCapsTheColumnCount() {
        // Width 1248 fits exactly five 240pt tiles with 12pt gaps
        // (5*240 + 4*12 = 1248), so the uncapped count is five.
        #expect(TileLayout.columnCount(width: 1248, minimumTileWidth: 240, spacing: 12) == 5)
        // The cap forces that down to three — the rule that keeps five or six
        // tiles from ever forming a single full-height row.
        #expect(TileLayout.columnCount(width: 1248, minimumTileWidth: 240, spacing: 12, maximum: 3) == 3)
    }

    @Test("the maximum only ever lowers, never raises, the fitted count")
    func maximumNeverRaises() {
        // Width 492 fits only two tiles; a maximum of three must not invent a
        // third column where the width cannot hold one.
        #expect(TileLayout.columnCount(width: 492, minimumTileWidth: 240, spacing: 12, maximum: 3) == 2)
    }

    @Test("a maximum still respects the one-column floor")
    func maximumKeepsTheOneColumnFloor() {
        // A degenerate width floors at one column; the cap cannot push it below.
        #expect(TileLayout.columnCount(width: 0, minimumTileWidth: 240, spacing: 12, maximum: 3) == 1)
    }

    @Test("the one-column floor holds even when the maximum is below one")
    func maximumBelowOneStillFloorsAtOne() {
        // columnCount is a pure helper with a total contract: it never returns
        // fewer than one column for any input, so the cap cannot push it to zero.
        #expect(TileLayout.columnCount(width: 500, minimumTileWidth: 240, spacing: 12, maximum: 0) == 1)
    }

    // MARK: Row chunking

    @Test("items are chunked into rows in order")
    func itemsChunkInOrder() {
        #expect(TileLayout.rows([1, 2, 3, 4, 5], columns: 2) == [[1, 2], [3, 4], [5]])
    }

    @Test("a single column gives one item per row")
    func singleColumnIsOnePerRow() {
        #expect(TileLayout.rows([1, 2, 3], columns: 1) == [[1], [2], [3]])
    }

    @Test("more columns than items yields one row")
    func moreColumnsThanItems() {
        #expect(TileLayout.rows([1, 2], columns: 8) == [[1, 2]])
    }

    @Test("no items yields no rows")
    func noItemsYieldsNoRows() {
        #expect(TileLayout.rows([Int](), columns: 3).isEmpty)
    }

    @Test("a nonsensical column count yields no rows rather than looping forever")
    func nonsensicalColumnCountIsSafe() {
        #expect(TileLayout.rows([1, 2, 3], columns: 0).isEmpty)
        #expect(TileLayout.rows([1, 2, 3], columns: -1).isEmpty)
    }

    @Test("a single row stretches to fill rather than padding empty columns")
    func singleRowDoesNotPad() {
        #expect(TileLayout.shouldPadShortRows(rowCount: 1) == false)
    }

    @Test("multiple rows pad, so columns line up down the grid")
    func multipleRowsPad() {
        #expect(TileLayout.shouldPadShortRows(rowCount: 2) == true)
    }

    @Test("every item appears exactly once across the rows")
    func chunkingLosesNothing() {
        let items = Array(1...17)
        let flattened = TileLayout.rows(items, columns: 4).flatMap { $0 }
        #expect(flattened == items)
    }
}
