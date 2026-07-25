import Foundation

/// Published peak memory bandwidth per Apple SoC, in GB/s.
///
/// This is specification data, not a measurement, and consumers must label it
/// as such. An unrecognised brand string returns `nil`; the UI then omits the
/// bandwidth line entirely rather than showing a guess.
public enum SoCBandwidth {
    /// A SoC is listed only when its brand string identifies exactly one
    /// bandwidth. Apple M3 Max is deliberately absent: its 14-core and 16-core
    /// binnings publish 300 and 400 GB/s respectively but report the identical
    /// `machdep.cpu.brand_string`, so the figure cannot be resolved from the
    /// brand alone. Omitting it yields `nil` and the UI drops the line, which
    /// is honest; listing one of the two values would state a confidently
    /// wrong number to half the owners of that chip.
    ///
    /// Any future SoC with the same ambiguity must be omitted for this reason.
    private static let table: [String: Double] = [
        "Apple M1": 68.25,
        "Apple M1 Pro": 200,
        "Apple M1 Max": 400,
        "Apple M1 Ultra": 800,
        "Apple M2": 100,
        "Apple M2 Pro": 200,
        "Apple M2 Max": 400,
        "Apple M2 Ultra": 800,
        "Apple M3": 100,
        "Apple M3 Pro": 150,
        "Apple M4": 120,
        "Apple M4 Pro": 273,
    ]

    public static func peakGBs(forBrand brand: String) -> Double? {
        table[brand.trimmingCharacters(in: .whitespaces)]
    }
}
