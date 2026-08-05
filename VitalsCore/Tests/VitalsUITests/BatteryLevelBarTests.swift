import SwiftUI
import Testing
@testable import VitalsUI

@MainActor
@Suite("Battery level bar")
struct BatteryLevelBarTests {

    /// Every colour here maps to a state macOS itself reports — none is a
    /// threshold this app chose.
    @Test("colour follows the system's own battery state")
    func colourFollowsSystemState() {
        #expect(BatteryLevelBar.fillColor(warningLevel: .none, isLowPowerMode: false)
                == Vitals.Palette.battery)
        #expect(BatteryLevelBar.fillColor(warningLevel: .final, isLowPowerMode: false)
                == Vitals.Palette.warning)
        #expect(BatteryLevelBar.fillColor(warningLevel: .none, isLowPowerMode: true)
                != Vitals.Palette.battery)
    }

    /// A battery about to die matters more than a power-saving preference.
    @Test("a warning outranks low power mode")
    func warningOutranksLowPowerMode() {
        #expect(BatteryLevelBar.fillColor(warningLevel: .final, isLowPowerMode: true)
                == Vitals.Palette.warning)
        #expect(BatteryLevelBar.fillColor(warningLevel: .early, isLowPowerMode: true)
                == BatteryLevelBar.fillColor(warningLevel: .early, isLowPowerMode: false))
    }

    /// Unlike the Sensors thermometer strip, charge is a bounded 0-100%
    /// quantity, so the bar needs no invented endpoints.
    @Test("the fill is proportional and clamped to the real range")
    func fillFractionIsProportional() {
        #expect(abs(BatteryLevelBar.fillFraction(percent: 0) - 0) < 1e-9)
        #expect(abs(BatteryLevelBar.fillFraction(percent: 22) - 0.22) < 1e-9)
        #expect(abs(BatteryLevelBar.fillFraction(percent: 100) - 1) < 1e-9)
        #expect(abs(BatteryLevelBar.fillFraction(percent: 140) - 1) < 1e-9)
    }

    @Test("the bar paints its fill at the right proportion")
    func barPaintsProportionally() throws {
        let rendered = try renderPNG(
            BatteryLevelBar(percent: 50, warningLevel: .none, isLowPowerMode: false)
                .frame(width: 400),
            size: CGSize(width: 400, height: 40), named: "battery-bar-half"
        )
        // Left half filled, right half empty.
        #expect(try regionHasSaturatedColor(in: rendered, region: CGRect(x: 20, y: 0, width: 60, height: 40)))
        #expect(try !regionHasSaturatedColor(in: rendered, region: CGRect(x: 320, y: 0, width: 60, height: 40)))
    }
}
