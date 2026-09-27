import AppKit
import Testing
@testable import VitalsUI

@Suite("App lifecycle")
struct AppLifecycleTests {

    /// A Dock icon only while the main window is open; the menu-bar item
    /// carries the app otherwise.
    @Test("the Dock icon follows the main window")
    func activationPolicyFollowsTheWindow() {
        #expect(AppLifecycle.activationPolicy(mainWindowOpen: true) == .regular)
        #expect(AppLifecycle.activationPolicy(mainWindowOpen: false) == .accessory)
    }
}
