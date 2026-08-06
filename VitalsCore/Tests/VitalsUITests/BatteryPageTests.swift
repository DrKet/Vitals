import Foundation
import SwiftUI
import SystemMetrics
import Testing
@testable import MetricsEngine
@testable import VitalsUI

@MainActor
@Suite("Battery page")
struct BatteryPageTests {

    /// Fails safe: an unrecognised verdict draws attention rather than being
    /// silently treated as fine. "Good" comes from the JSON output and
    /// "Normal" from the text output — both have been observed for a healthy
    /// battery, and Vitals reads the JSON.
    @Test("only known-healthy conditions read as healthy")
    func conditionFailsSafe() {
        #expect(BatteryPage.conditionIsHealthy("Good"))
        #expect(BatteryPage.conditionIsHealthy("Normal"))
        #expect(BatteryPage.conditionIsHealthy("Service Recommended") == false)
        #expect(BatteryPage.conditionIsHealthy("Check Battery") == false)
        // Never seen before, so it must NOT read as healthy.
        #expect(BatteryPage.conditionIsHealthy("Excellent") == false)
    }

    @Test("an unmeasurable time estimate renders as an em dash, never a zero")
    func absentTimeRendersAsEmDash() {
        #expect(BatteryPage.displayMinutes(nil) == "—")
        #expect(BatteryPage.displayMinutes(79) == "1:19")
        #expect(BatteryPage.displayMinutes(45) == "0:45")
    }

    @Test("power is formatted to one decimal with a watt suffix")
    func powerFormatting() {
        #expect(BatteryPage.displayWatts(11.646) == "11.6 W")
        #expect(BatteryPage.displayWatts(nil) == "—")
    }

    /// Four states, not three. Plugged in and NOT charging is two different
    /// situations, and only one of them is "Charged".
    ///
    /// Measured on this machine the moment the adapter went in at 73%:
    /// `ExternalConnected` Yes, `IsCharging` No, `FullyCharged` No — while
    /// `pmset` said "AC attached; not charging". Reading that as "Charged"
    /// would put "73% – Charged" on screen, which is a claim the machine
    /// never made. macOS holds this state deliberately and for long periods
    /// under optimised battery charging, so it is a normal reading, not a
    /// transient worth ignoring.
    @Test("plugged in but not yet full does not claim to be charged")
    func acAttachedNotChargingIsNotCharged() {
        #expect(BatteryPage.chargeStateDescription(
            isCharging: false, isExternalPowerConnected: true, isFullyCharged: false
        ) == "Not charging")
        #expect(BatteryPage.chargeStateDescription(
            isCharging: false, isExternalPowerConnected: true, isFullyCharged: true
        ) == "Charged")
        #expect(BatteryPage.chargeStateDescription(
            isCharging: true, isExternalPowerConnected: true, isFullyCharged: false
        ) == "Charging")
        // On battery, fullness is irrelevant — nothing is plugged in to be
        // charged by, so a full battery still reads "On battery".
        #expect(BatteryPage.chargeStateDescription(
            isCharging: false, isExternalPowerConnected: false, isFullyCharged: true
        ) == "On battery")
    }
}
