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

    /// The track's own thickness.
    ///
    /// Fixed, and deliberately chrome-weight. An earlier version let a
    /// `GeometryReader` size the track, so it grew to fill whatever the page's
    /// `secondary` slot offered — about 108pt, nearly as tall as the
    /// temperature chart above it. A scale is not data and must not compete
    /// with it. At this thickness the capsule's cap radius is 6pt rather than
    /// 54pt, which is the other half of why the old one read as a lozenge
    /// instead of a scale.
    static let trackHeight: CGFloat = 12

    /// Row reserved above the track for the reading's own label.
    ///
    /// Constant whether or not there is a reading, so the strip does not
    /// change height when a sensor drops out and the page does not jump.
    static let readingRowHeight: CGFloat = 16

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                // No label without a reading, for the same reason there is no
                // marker: see the marker's comment below.
                if let celsius {
                    // Placed through `ReadoutPlacement` rather than a raw
                    // offset so the label cannot overhang either end of the
                    // track. That type already solves exactly this — anchor a
                    // single subview near an x and clamp it inside the bounds
                    // — and it measures the subview during layout, so nothing
                    // here has to assume how wide "36.4°" renders.
                    ReadoutPlacement(anchorX: proxy.size.width * Self.markerFraction(for: celsius)) {
                        Text(Self.readingLabel(for: celsius))
                            .font(Vitals.Typography.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: Self.readingRowHeight)

            ZStack(alignment: .leading) {
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
            }
            .frame(height: Self.trackHeight)

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

    /// The reading itself, shown on the marker.
    ///
    /// Without it the strip shows a position and nothing else: the page's
    /// headline sits far above, and a reader has to infer that the mark at
    /// roughly a fifth of the way along corresponds to it. One decimal, to
    /// match `ChartUnit.temperature.formatted(_:)` rather than implying a
    /// different precision from the same number elsewhere on the page.
    static func readingLabel(for celsius: Double) -> String {
        String(format: "%.1f\u{00B0}", celsius)
    }
}
