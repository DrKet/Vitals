import CoreGraphics
import SwiftUI

/// Arithmetic for a tile grid that fills its container.
///
/// `LazyVGrid` sizes its rows to their content, so a grid of two tiles in a tall
/// window leaves everything below them empty. A monitoring app cannot afford
/// that — leftover vertical space belongs to the data. These pure helpers let
/// the grid compute its own rows so each one can claim an equal share of the
/// height.
public enum TileLayout {

    /// How many tiles fit across `width`, never fewer than one and never more
    /// than `maximum`. The cap only lowers the fitted count — it is what keeps
    /// five or six tiles from collapsing into a single full-height row on a
    /// wide window.
    ///
    /// Solves `n * minimum + (n - 1) * spacing <= width` for `n`.
    public static func columnCount(
        width: CGFloat,
        minimumTileWidth: CGFloat,
        spacing: CGFloat,
        maximum: Int = .max
    ) -> Int {
        guard width > 0, minimumTileWidth > 0 else { return 1 }
        let fitted = Int((width + spacing) / (minimumTileWidth + spacing))
        return max(min(fitted, maximum), 1)
    }

    /// Whether a short final row should be padded with empty cells.
    ///
    /// Padding keeps tiles the same width down a multi-row grid, so columns line
    /// up. With a single row there is nothing to line up with, and padding just
    /// strands empty space beside the tiles — so a lone row stretches to fill.
    public static func shouldPadShortRows(rowCount: Int) -> Bool {
        rowCount > 1
    }

    /// Splits items into rows of at most `columns`, preserving order.
    public static func rows<Item>(_ items: [Item], columns: Int) -> [[Item]] {
        guard columns > 0, !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: columns).map { start in
            Array(items[start..<min(start + columns, items.count)])
        }
    }
}

/// A grid whose tiles reflow by width and grow into available height.
public struct TileGrid<Item: Identifiable, Tile: View>: View {
    private let items: [Item]
    private let minimumTileWidth: CGFloat
    private let spacing: CGFloat
    private let tile: (Item) -> Tile

    public init(
        items: [Item],
        minimumTileWidth: CGFloat = 240,
        spacing: CGFloat = Vitals.Metrics.tileSpacing,
        @ViewBuilder tile: @escaping (Item) -> Tile
    ) {
        self.items = items
        self.minimumTileWidth = minimumTileWidth
        self.spacing = spacing
        self.tile = tile
    }

    public var body: some View {
        GeometryReader { proxy in
            let columns = TileLayout.columnCount(
                width: proxy.size.width,
                minimumTileWidth: minimumTileWidth,
                spacing: spacing
            )
            let rows = TileLayout.rows(items, columns: columns)

            VStack(spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { item in
                            tile(item)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if TileLayout.shouldPadShortRows(rowCount: rows.count),
                           row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }
}
