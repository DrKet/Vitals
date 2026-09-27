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
                Self.sparkline(series: tile.series, accent: tile.accent)
            }
        }
        .contentShape(Rectangle())
    }

    /// The height every row's chart is given. `MetricChart` itself floors at
    /// `Vitals.Metrics.chartHeight` (132pt) unless told otherwise — passed
    /// here as `minimumHeight` so the dropdown actually gets a 28pt
    /// sparkline instead of a 132pt chart silently overflowing its row.
    /// `.clipped()` is the second half of that: it stops the glow bloom and
    /// the live-dot halo, which can paint outside the chart's own plot rect,
    /// from bleeding into the next row either.
    static let sparklineHeight: CGFloat = 28

    static func sparkline(series: [ChartSeries], accent: Color) -> some View {
        MetricChart(
            series: series,
            style: .area(stacked: series.count > 1),
            colors: [accent],
            showsAxisMaximum: false,
            minimumHeight: Self.sparklineHeight
        )
        .frame(height: Self.sparklineHeight)
        .clipped()
    }
}
