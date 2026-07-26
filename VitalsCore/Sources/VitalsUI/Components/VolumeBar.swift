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
                Text("\(Self.format(volume.usedBytes)) of \(Self.format(volume.totalBytes))")
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

    /// `Volume`'s byte counts are plain `UInt64`s, never optional, so
    /// `Vitals.formatByteCount` — generic over an optional so a genuinely
    /// absent reading elsewhere can propagate `nil` — always takes its
    /// non-nil branch here. Force-unwrapping documents that rather than
    /// inventing an `?? "…"` fallback string that could never actually show.
    private static func format(_ bytes: UInt64) -> String {
        Vitals.formatByteCount(bytes)!
    }
}
