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
    public static func displayValue(_ value: String?) -> String {
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
                    MetricChart(series: series, style: .area(stacked: series.count > 1), colors: [accent])
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
