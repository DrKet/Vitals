import SwiftUI

/// One labelled statistic in a hardware page's key-stats block.
public struct HardwareStat: Identifiable, Sendable, Equatable {
    public let label: String
    /// `nil` renders as "Unavailable" via `StatRow` — never as `0` or blank.
    public let value: String?

    public var id: String { label }

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }
}

/// The shared shape of every hardware page, from spec §6.2: title with vendor
/// mark, large primary value, primary chart, an optional secondary
/// visualisation, four key statistics, and a sticky *Full specifications*
/// disclosure.
///
/// Extracted so the five pages are identical by construction rather than by
/// five people remembering to keep them in step.
public struct HardwarePage<Secondary: View, Specs: View>: View {
    private let title: String
    private let vendorName: String?
    private let showsAppleMark: Bool
    private let primaryValue: String?
    private let series: [ChartSeries]
    /// The hue this page's Overview tile already uses. Leads the chart's
    /// colour ramp so a glance at the chart identifies its subject without
    /// reading the label — see `Design/Tokens.swift`'s doc comment. Every
    /// page used to fall through to `Vitals.seriesColors(count:)`'s default
    /// ramp, which always starts at `Palette.cpu`; that was the bug this
    /// parameter fixes.
    private let accent: Color
    private let stats: [HardwareStat]
    private let secondary: Secondary
    private let specifications: Specs

    /// `@SceneStorage`, not `@State`: `AppShell` rebuilds the page on every
    /// sidebar switch, which would reset plain state. The spec requires the
    /// disclosure to stay open once expanded, so it must survive teardown.
    @SceneStorage private var showFullSpecifications: Bool

    public init(
        title: String,
        vendorName: String?,
        showsAppleMark: Bool,
        primaryValue: String?,
        series: [ChartSeries],
        accent: Color,
        stats: [HardwareStat],
        disclosureKey: String,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder specifications: () -> Specs
    ) {
        self.title = title
        self.vendorName = vendorName
        self.showsAppleMark = showsAppleMark
        self.primaryValue = primaryValue
        self.series = series
        self.accent = accent
        self.stats = stats
        self.secondary = secondary()
        self.specifications = specifications()
        self._showFullSpecifications = SceneStorage(wrappedValue: false, disclosureKey)
    }

    /// An absent primary reading shows an em dash. Never "0", never blank.
    public static func displayPrimary(_ value: String?) -> String {
        value ?? "—"
    }

    public var body: some View {
        // A plain `Spacer()` inside a bare `ScrollView` does nothing — the
        // scroll view proposes unbounded height to its content, so a trailing
        // spacer collapses to zero. `GeometryReader` supplies the visible
        // height so the content `VStack` can be told to fill at least that
        // much, which is what lets the spacer push against something on a
        // tall window instead of leaving blank scroll-view background below
        // the last panel. Content taller than the window still scrolls
        // normally.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Vitals.Metrics.tileSpacing) {
                    header

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Self.displayPrimary(primaryValue))
                                .font(Vitals.Typography.readout)
                                .foregroundStyle(primaryValue == nil ? .secondary : .primary)

                            if !series.isEmpty {
                                MetricChart(
                                    series: series,
                                    style: .area(stacked: series.count > 1),
                                    colors: Vitals.seriesColors(startingAt: accent, count: max(series.count, 1))
                                )
                                // The cap lives here, not inside `MetricChart`:
                                // Overview tiles embed the same chart and size
                                // it from the tile's own geometry, and they do
                                // not have this problem. See
                                // `Metrics.chartMaxHeight`.
                                .frame(maxHeight: Vitals.Metrics.chartMaxHeight)
                            }

                            secondary
                        }
                    }

                    if !stats.isEmpty {
                        GlassPanel {
                            VStack(spacing: 0) {
                                ForEach(stats) { stat in
                                    StatRow(label: stat.label, value: stat.value)
                                }
                            }
                        }
                    }

                    GlassPanel {
                        DisclosureGroup(isExpanded: $showFullSpecifications) {
                            VStack(spacing: 0) { specifications }
                                .padding(.top, 6)
                        } label: {
                            Text("Full specifications").font(Vitals.Typography.label)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(Vitals.Typography.sectionTitle)
            Spacer()
            if let vendorName {
                HStack(spacing: 6) {
                    // The Apple mark is a glyph in the system font, so no asset
                    // is bundled for it.
                    if showsAppleMark { Text("\u{F8FF}") }
                    Text(vendorName)
                }
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassSurface(cornerRadius: 20)
            }
        }
    }
}
