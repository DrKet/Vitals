import SwiftUI

/// One glass tile on the Overview grid: a label, a large value, and a sparkline.
public struct MetricTile: View {
    private let label: String
    private let value: String?
    private let accent: Color
    private let series: [ChartSeries]

    public init(label: String, value: String?, accent: Color, series: [ChartSeries]) {
        self.label = label
        self.value = value
        self.accent = accent
        self.series = series
    }

    /// An absent reading shows an em dash. Never "0", never blank — a monitor
    /// that cannot measure something must not appear to have measured zero.
    ///
    /// House rule, split by shape: large numeric readouts (this) use the em
    /// dash; labelled label/value rows (`StatRow.displayValue`) use the word
    /// "Unavailable". Both must be styled as absence, never as a reading.
    ///
    /// `nonisolated` because this touches no `View` state — it's a pure
    /// string mapping — and `ProcessRow`, which has no SwiftUI in it, needs
    /// to call it from a plain nonisolated context without forcing itself
    /// onto the main actor just to word an absent value.
    public nonisolated static func displayValue(_ value: String?) -> String {
        value ?? "—"
    }

    public var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
                    .tracking(0.8)

                Text(Self.displayValue(value))
                    .font(Vitals.Typography.tileValue)
                    .foregroundStyle(value == nil ? .secondary : .primary)

                if series.contains(where: { !$0.values.isEmpty }) {
                    // The tile's own headline (`value` above) already states
                    // this reading — an axis-maximum label would restate it a
                    // second time in 11pt grey directly beneath it. See
                    // `MetricChart.init`'s doc comment for why this parameter
                    // has no default that could silently reintroduce that.
                    MetricChart(
                        series: series,
                        style: .area(stacked: series.count > 1),
                        colors: [accent],
                        showsAxisMaximum: false
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
