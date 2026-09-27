import SwiftUI

/// The menu-bar readout: CPU and memory, each a symbol and a value, digits
/// monospaced so the item's width does not jitter as values change. No store
/// yet (still starting, or startup failed) reads as em dashes, like any
/// unmeasured value.
public struct MenuBarLabel: View {
    private let store: MetricsStore?

    public init(store: MetricsStore?) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
            Text(MenuBarReadout.cpu(store?.cpu)).monospacedDigit()
            Image(systemName: "memorychip")
            Text(MenuBarReadout.memory(store?.memory, totalBytes: store?.profile?.memory.totalBytes))
                .monospacedDigit()
        }
    }
}
