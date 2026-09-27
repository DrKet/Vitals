import AppKit

/// How Vitals presents itself as an app.
public enum AppLifecycle {

    /// A Dock icon and Cmd-Tab entry only while the main window is open. With
    /// it closed, Vitals keeps running as an accessory: the menu-bar item is
    /// its only presence, which is the point of having one.
    public static func activationPolicy(mainWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        mainWindowOpen ? .regular : .accessory
    }
}
