import SwiftUI

/// The menu-bar dropdown: one row per kept-warm subsystem — built by the
/// Overview's own `OverviewTiles`, so each value is the tile's — and a footer.
///
/// Actions are closures so the panel renders in tests without an app; the app
/// supplies window-opening and quitting.
public struct MenuBarPanel: View {
    public static let width: CGFloat = 320

    /// The kept-warm series, in Overview order. Battery and Sensors are left
    /// out: they are not kept warm, so a row for them would be empty until a
    /// subscription of its own filled it.
    static let rowIDs = OverviewPage.tileOrder(hasBattery: false)

    private let store: MetricsStore
    private let onOpenPage: (SidebarSection) -> Void
    private let onOpenVitals: () -> Void
    private let onQuit: () -> Void

    public init(
        store: MetricsStore,
        onOpenPage: @escaping (SidebarSection) -> Void,
        onOpenVitals: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenPage = onOpenPage
        self.onOpenVitals = onOpenVitals
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(OverviewTiles.tiles(ids: Self.rowIDs, store: store)) { tile in
                Button {
                    if let section = SidebarSection(rawValue: tile.id) { onOpenPage(section) }
                } label: {
                    row(tile)
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Open Vitals", action: onOpenVitals)
                Spacer()
                Button("Quit Vitals", action: onQuit)
            }
        }
        .padding(12)
        .frame(width: Self.width)
    }

    private func row(_ tile: OverviewTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tile.label).font(Vitals.Typography.label)
                Spacer()
                Text(MetricTile.displayValue(tile.value))
                    .font(Vitals.Typography.label)
                    .monospacedDigit()
            }
            if !tile.series.isEmpty {
                MetricChart(
                    series: tile.series,
                    style: .area(stacked: tile.series.count > 1),
                    colors: [tile.accent],
                    showsAxisMaximum: false
                )
                .frame(height: 28)
            }
        }
        .contentShape(Rectangle())
    }
}
