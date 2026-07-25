import SwiftUI

private struct VitalsGlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether `glassSurface()` uses the real Liquid Glass material.
    ///
    /// True everywhere in the running app. The offscreen render harness sets it
    /// false, because `.glassEffect` draws nothing at all through
    /// `ImageRenderer` — not the material, and not its children either — which
    /// would make every render test a blank image and every assertion vacuous.
    public var vitalsGlassEnabled: Bool {
        get { self[VitalsGlassEnabledKey.self] }
        set { self[VitalsGlassEnabledKey.self] = newValue }
    }
}

/// The house surface: Liquid Glass in a rounded rectangle.
///
/// Every panel, tile, and widget in Vitals sits on this, so the app reads as one
/// material rather than an assortment of boxes.
struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.vitalsGlassEnabled) private var glassEnabled
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if glassEnabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            // Same geometry, a material that renders offscreen. Test-only path.
            content.background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        }
    }
}

extension View {
    public func glassSurface(cornerRadius: CGFloat = Vitals.Metrics.cornerRadius) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius))
    }
}

/// A padded glass container.
public struct GlassPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(
        cornerRadius: CGFloat = Vitals.Metrics.cornerRadius,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(Vitals.Metrics.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: cornerRadius)
    }
}
