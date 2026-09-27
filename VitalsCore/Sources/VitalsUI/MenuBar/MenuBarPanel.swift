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

    /// Layout constants `body` and `row(_:)` actually lay out with — named,
    /// not inline literals, so `MenuBarPanelTests` can derive each row's
    /// probe band from the same numbers the layout uses instead of a second,
    /// hand-pinned copy that could silently drift from it.
    static let padding: CGFloat = 12
    /// Spacing inside one `row(_:)`, between its label line and its chart.
    static let rowInnerSpacing: CGFloat = 4
    /// Spacing in `body`'s outer `VStack`, between rows and before/after the
    /// footer divider.
    static let rowSpacing: CGFloat = 10

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
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
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
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    private func row(_ tile: OverviewTile) -> some View {
        VStack(alignment: .leading, spacing: Self.rowInnerSpacing) {
            HStack {
                Text(tile.label).font(Vitals.Typography.label)
                Spacer()
                Text(MetricTile.displayValue(tile.value))
                    .font(Vitals.Typography.label)
                    .monospacedDigit()
            }
            if tile.series.hasPlottableValues {
                Self.sparkline(series: tile.series, accent: tile.accent)
            }
        }
        .contentShape(Rectangle())
    }

    /// The height every row's chart is given. `MetricChart` itself floors at
    /// `Vitals.Metrics.chartHeight` (132pt) unless told otherwise — passed
    /// here as `minimumHeight` so the dropdown actually gets a 28pt
    /// sparkline instead of a 132pt chart silently overflowing its row. That
    /// alone is the fix for the bleed into the row below: `Canvas` already
    /// bounds its own drawing to whatever frame it is actually given, so
    /// once `minimumHeight` and this `.frame(height:)` agree, there is
    /// nothing left for a clip to do. `.clipped()` below is kept anyway as
    /// defence in depth, not because it is load-bearing today.
    static let sparklineHeight: CGFloat = 28

    static func sparkline(series: [ChartSeries], accent: Color) -> some View {
        MetricChart(
            series: series,
            style: .area(stacked: series.count > 1),
            colors: [accent],
            showsAxisMaximum: false,
            minimumHeight: Self.sparklineHeight,
            // `Canvas` rasterises into a buffer sized to its own frame, and
            // the live dot's halo is centred exactly on the plot's trailing
            // edge — so no *outer* clip (or its absence) can recover the
            // half that falls past that edge; only insetting the plot
            // itself, inside `MetricChart`, actually works (verified: a
            // 100pt clip-shape outset and no clip at all rendered
            // byte-identical, both still cutting the dot in half). Asking
            // for it by name rather than passing a copied radius keeps the
            // one number (`MetricChart.liveDotHaloRadius`) in one place, and
            // keeps the renderer and `MetricChart`'s own crosshair plotting
            // against the exact same rect — see `MetricChart.plotRect`'s
            // doc comment. Safe to ask for here because this sparkline's
            // hit-testing is off below, so its crosshair never engages.
            reservesTrailingLiveDotRoom: true
        )
        .frame(height: Self.sparklineHeight)
        // Nothing left for this to clip vertically (see `sparklineHeight`'s
        // doc comment) or horizontally (the live dot's halo already fits
        // inside this frame, via `reservesTrailingLiveDotRoom` above) — kept
        // as defence in depth against a future regression in either, not
        // because either bleed is real today.
        .clipped()
        // The row's own `.contentShape(Rectangle())` (see `row(_:)`) is what
        // makes the whole row clickable; without disabling hit-testing here,
        // `MetricChart`'s own hover crosshair and ~40pt-wide readout box
        // would compete for pointer events inside a 28pt clipped row, on the
        // dropdown's main click-to-open-page path. No render test can drive
        // a hover, so this is a live-app check, not an automated one.
        .allowsHitTesting(false)
    }
}
