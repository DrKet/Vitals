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
            if Self.hasChartData(tile.series) {
                Self.sparkline(series: tile.series, accent: tile.accent)
            }
        }
        .contentShape(Rectangle())
    }

    /// The same emptiness rule `MetricTile` uses (`MetricTile.swift`, ~line
    /// 50: `series.contains(where: { !$0.values.isEmpty })`), not the looser
    /// `!series.isEmpty`. The CPU tile's series is always exactly one
    /// `ChartSeries` — on a freshly empty store it is present but carries no
    /// values, so `!series.isEmpty` alone would still be true and `row(_:)`
    /// would reserve a chart band (drawing faint gridlines) for a reading
    /// that was never taken. A single predicate shared with `MetricTile`
    /// would be the more natural home for this, but this fix is scoped to
    /// `MenuBarPanel.swift` and its test, so the rule is duplicated here
    /// rather than touching `MetricTile.swift`.
    static func hasChartData(_ series: [ChartSeries]) -> Bool {
        series.contains(where: { !$0.values.isEmpty })
    }

    /// The height every row's chart is given. `MetricChart` itself floors at
    /// `Vitals.Metrics.chartHeight` (132pt) unless told otherwise — passed
    /// here as `minimumHeight` so the dropdown actually gets a 28pt
    /// sparkline instead of a 132pt chart silently overflowing its row.
    /// `.clipped()` is the second half of that: it stops the glow bloom from
    /// bleeding into the next row.
    static let sparklineHeight: CGFloat = 28

    /// Mirrors `MetricChart`'s own private `liveDotHaloRadius` (`MetricChart.swift`,
    /// 9pt) — duplicated rather than referenced because that constant is not
    /// exposed, and exposing it is out of this fix's scope. If the halo's
    /// radius there ever changes, this should follow.
    private static let liveDotHaloRadius: CGFloat = 9

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
            // byte-identical, both still cutting the dot in half). Safe to
            // ask for here because this sparkline's hit-testing is off
            // below, so its crosshair — the one thing a trailing inset could
            // otherwise put out of step with — never engages.
            trailingHeadroom: Self.liveDotHaloRadius
        )
        .frame(height: Self.sparklineHeight)
        // Clips vertically to this frame — the fix for the chart bleeding
        // into the row below. Nothing to cut off horizontally any more: the
        // `trailingHeadroom` above already keeps the live dot's halo inside
        // this same frame, so a plain `.clipped()` is enough on both axes.
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
