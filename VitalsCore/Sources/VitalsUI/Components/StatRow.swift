import SwiftUI

/// A label and its value. A `nil` value reads "Unavailable" in secondary colour
/// rather than showing a blank the eye interprets as zero.
public struct StatRow: View {
    private let label: String
    private let value: String?

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(Vitals.Typography.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "Unavailable")
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
