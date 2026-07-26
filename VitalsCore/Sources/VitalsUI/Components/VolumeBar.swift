import SwiftUI
import SystemMetrics

/// One volume's capacity as a labelled bar.
public struct VolumeBar: View {
    private let volume: Volume
    private let accent: Color

    public init(volume: Volume, accent: Color) {
        self.volume = volume
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(volume.name).font(Vitals.Typography.label)
                Spacer()
                Text("\(Vitals.formatKnownByteCount(volume.usedBytes)) of \(Vitals.formatKnownByteCount(volume.totalBytes))")
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule()
                        .fill(accent)
                        .frame(width: proxy.size.width * volume.usedFraction)
                }
            }
            .frame(height: 8)
        }
    }
}
