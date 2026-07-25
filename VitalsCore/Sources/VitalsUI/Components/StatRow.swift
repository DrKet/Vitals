import SwiftUI

/// A label and its value. A `nil` value reads "Unavailable" in secondary colour
/// rather than showing a blank the eye interprets as zero.
///
/// House rule for the never-fabricate-a-number principle, split by shape:
/// large numeric readouts (`MetricTile.displayValue`) use the em dash;
/// labelled label/value rows (this type) use the word "Unavailable". Both
/// must be styled as absence, never as a reading — a helper upstream of
/// either one must hand back `nil`, never a baked-in placeholder string, or
/// the row loses the ability to tell "no data" from "the word 'Unavailable'
/// is the actual reading."
public struct StatRow: View {
    private let label: String
    private let value: String?

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }

    /// An absent reading shows the word "Unavailable". Never "0", never
    /// blank — the label/value counterpart to `MetricTile.displayValue`'s em
    /// dash.
    public static func displayValue(_ value: String?) -> String {
        value ?? "Unavailable"
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(Self.displayValue(value))
                .font(Vitals.Typography.label)
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
        }
    }
}
