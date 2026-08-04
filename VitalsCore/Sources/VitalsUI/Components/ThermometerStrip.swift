import SwiftUI

/// One reading's position on a fixed 20-100 degC gradient scale.
///
/// The domain is pinned rather than derived from the reading the way the
/// page's own chart is: a spike measured the hottest die on this machine
/// moving only 2.13 degC across a full CPU load ramp. A chart's floating
/// baseline is what makes that 2 degC of motion visible at all; a colour
/// scale that floated the same way would mean a different temperature on
/// every render, which defeats the point of a colour scale. Fixing the
/// endpoints here is what lets a colour on this strip always mean the same
/// temperature, in exchange for never showing the trend — that job stays
/// with the chart.
///
/// Carries no danger zone, red band, or threshold mark on purpose: `20` and
/// `100` are a display scale picked so a colour gradient reads clearly, not
/// a measured limit. The spike this shipped from never established what
/// this hardware's actual thermal limits are, so drawing a line here would
/// assert something about the machine that was never measured.
public struct ThermometerStrip: View {
    private let celsius: Double?

    public static let minimumCelsius = 20.0
    public static let maximumCelsius = 100.0

    /// Cool end of the ramp. Kept well under full brightness (max channel
    /// 0.65) — not for looks, but so a render-test brightness probe can
    /// tell the always-drawn track from the marker painted on top of it.
    /// See `ThermometerStripTests`.
    private static let coolColor = Color(red: 0.25, green: 0.45, blue: 0.65)

    /// Warm end of the ramp. Deliberately not `Vitals.Palette.warning`:
    /// that red means "something is wrong" everywhere else in the app, and
    /// reusing it on the one page most likely to be misread as a thermal
    /// limit would say something the fixed domain was designed specifically
    /// not to say.
    ///
    /// Cool-to-warm here runs blue-to-amber, the opposite of the Kelvin
    /// colour-temperature scale, where low Kelvin reads orange and high
    /// Kelvin reads blue. A literal Kelvin ramp would paint the hottest
    /// readings blue, which reads backwards to anyone who has ever seen a
    /// thermostat.
    private static let warmColor = Color(red: 0.70, green: 0.48, blue: 0.20)

    private static let markerColor = Color.white

    public init(celsius: Double?) {
        self.celsius = celsius
    }

    /// Where `celsius` sits along the fixed track, clamped to it.
    ///
    /// Clamped rather than extrapolated: a reading past the end of the
    /// display scale is still a real reading, and drawing its marker off
    /// the track would lose it entirely rather than show it pinned at the
    /// end nearest its true value.
    static func markerFraction(for celsius: Double) -> Double {
        let span = maximumCelsius - minimumCelsius
        return min(max((celsius - minimumCelsius) / span, 0), 1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Self.coolColor, Self.warmColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    // No marker at all for a `nil` reading — not a marker
                    // pinned to `minimumCelsius`, which is what treating an
                    // unmeasurable value as zero (or as the scale's floor)
                    // would look like on this track.
                    if let celsius {
                        let fraction = Self.markerFraction(for: celsius)
                        Capsule()
                            .fill(Self.markerColor)
                            .frame(width: 4)
                            .offset(x: proxy.size.width * fraction - 2)
                    }
                }
            }

            HStack {
                Text(Self.label(for: Self.minimumCelsius))
                Spacer()
                Text(Self.label(for: Self.maximumCelsius))
            }
            .font(Vitals.Typography.label)
            .foregroundStyle(.secondary)
        }
    }

    private static func label(for celsius: Double) -> String {
        "\(Int(celsius))\u{00B0}"
    }
}
