import SwiftUI
import SystemMetrics

/// A battery glyph, its charge percentage, and a proportional fill track.
///
/// Unlike `ThermometerStrip`, charge needs no invented display domain: a
/// percentage is already bounded 0-100, so the track's fraction is the
/// reading itself, not a position on a scale someone had to choose the
/// endpoints for.
public struct BatteryLevelBar: View {
    private let percent: Int
    private let warningLevel: BatteryWarningLevel
    private let isLowPowerMode: Bool

    /// The track's own thickness, fixed for the same reason
    /// `ThermometerStrip.trackHeight` is: an unconstrained `GeometryReader`
    /// sizes itself to whatever space a `VStack` offers it, not to the
    /// track's actual visual weight, and grew to fill the page's `secondary`
    /// slot the one time this project tried it unconstrained.
    static let trackHeight: CGFloat = 12

    /// Empty portion of the track. Deliberately neutral (equal R/G/B) rather
    /// than any accent: `regionHasSaturatedColor`, the render probe that
    /// tells a filled pixel from an empty one, can only draw that line if the
    /// empty track carries no hue of its own to confuse it with the fill.
    private static let trackBackground = Color.white.opacity(0.10)

    /// Low Power Mode's colour. Distinct from `Vitals.Palette.battery` so a
    /// user can tell "charge is fine, but the system throttled itself" from
    /// "charge is fine" at a glance — the whole reason this state has its own
    /// colour instead of just leaving the bar green.
    private static let lowPowerColor = Color(red: 0.95, green: 0.85, blue: 0.35)

    /// `early` warning colour. Sits between the low-power yellow and
    /// `Vitals.Palette.warning`'s red so the two warning levels
    /// (`early`/`final`) read as escalating severity rather than an
    /// arbitrary pair of unrelated colours.
    private static let earlyWarningColor = Color(red: 0.95, green: 0.60, blue: 0.20)

    public init(percent: Int, warningLevel: BatteryWarningLevel, isLowPowerMode: Bool) {
        self.percent = percent
        self.warningLevel = warningLevel
        self.isLowPowerMode = isLowPowerMode
    }

    /// Colour by system state. Warning level outranks Low Power Mode: a
    /// battery about to die matters more than a power-saving preference.
    static func fillColor(warningLevel: BatteryWarningLevel, isLowPowerMode: Bool) -> Color {
        switch warningLevel {
        case .final: return Vitals.Palette.warning
        case .early: return Self.earlyWarningColor
        case .none: return isLowPowerMode ? Self.lowPowerColor : Vitals.Palette.battery
        }
    }

    /// Charge is a bounded 0-100% quantity, so unlike `ThermometerStrip` this
    /// needs no invented endpoints. Clamped because a gas gauge can briefly
    /// report over 100 while calibrating.
    static func fillFraction(percent: Int) -> Double {
        min(max(Double(percent) / 100, 0), 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "battery.100")
                    .font(Vitals.Typography.label)
                    .foregroundStyle(.secondary)
                Text("\(percent)%")
                    .font(Vitals.Typography.tileValue)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Self.trackBackground)
                    Capsule()
                        .fill(Self.fillColor(warningLevel: warningLevel, isLowPowerMode: isLowPowerMode))
                        .frame(width: proxy.size.width * Self.fillFraction(percent: percent))
                }
            }
            .frame(height: Self.trackHeight)
        }
    }
}
