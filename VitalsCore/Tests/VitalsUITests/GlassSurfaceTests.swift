import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Glass surface")
struct GlassSurfaceTests {

    @Test("a glass panel renders at the requested size")
    func panelRenders() throws {
        let panel = GlassPanel {
            VStack(alignment: .leading) {
                Text("PROCESSOR").font(Vitals.Typography.label)
                Text("18%").font(Vitals.Typography.readout)
            }
        }
        let url = try renderPNG(panel, size: CGSize(width: 240, height: 140), named: "glass-panel")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the surface modifier composes onto an arbitrary view")
    func modifierComposes() throws {
        let view = Text("42").padding().glassSurface()
        let url = try renderPNG(view, size: CGSize(width: 120, height: 80), named: "glass-modifier")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("real glass is the default; only the harness turns it off")
    func glassIsOnByDefault() {
        // Guards against the test-only fallback ever becoming the app's
        // appearance by accident.
        #expect(EnvironmentValues().vitalsGlassEnabled == true)
    }
}
