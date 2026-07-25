import SwiftUI
import SystemMetrics

/// Per-core busy fractions as a row of vertical bars.
public struct CoreGrid: View {
    private let cores: [CoreLoad]
    private let accent: Color

    public init(cores: [CoreLoad], accent: Color) {
        self.cores = cores
        self.accent = accent
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(Array(cores.enumerated()), id: \.offset) { _, core in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.10))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent)
                            .frame(height: proxy.size.height * min(max(core.busy, 0), 1))
                    }
                }
            }
        }
        .frame(height: 34)
    }
}
