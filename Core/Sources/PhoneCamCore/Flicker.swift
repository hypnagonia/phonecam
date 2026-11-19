import Foundation

/// Lamps on mains power flicker at twice the mains frequency (100 Hz on 50 Hz power, 120 Hz on 60 Hz).
/// A shutter that is a whole number of those flicker periods sees the same light in every row and frame,
/// so the picture shows no rolling bands.
public enum Flicker {
    /// Countries and territories on 60 Hz mains; everything else is treated as 50 Hz.
    /// (Japan is split; it is treated as 50 Hz, the user can switch.)
    static let sixtyHz: Set<String> = ["US", "CA", "MX", "BR", "CO", "VE", "EC", "PE", "KR", "TW", "PH", "SA",
                                        "CU", "DO", "GT", "HN", "NI", "CR", "PA", "SV", "PR", "BS", "BZ", "TT",
                                        "LR", "GU", "AS", "MP", "VI", "BM", "KY", "AW", "MS", "FM", "MH", "PW"]

    /// Mains frequency for a region code (ISO 3166, e.g. "US"); 50 when unknown.
    public static func mainsHz(region: String?) -> Int {
        guard let r = region?.uppercased() else { return 50 }
        return sixtyHz.contains(r) ? 60 : 50
    }

    /// The longest flicker-free shutter not longer than `longest` (seconds): k / (2·mains).
    /// `longest` itself when even one flicker period is longer (very high frame rates).
    public static func safeShutter(mains: Int, longest: Double) -> Double {
        let period = 1 / Double(2 * mains)
        let k = (longest / period + 1e-9).rounded(.down)
        return k >= 1 ? k * period : longest
    }

    /// A manual shutter moved to the nearest flicker-free value. Shutters shorter than one flicker period
    /// are left alone (they cannot avoid flicker anyway), and the result never exceeds `longest`.
    public static func snap(_ s: Double, mains: Int, longest: Double) -> Double {
        let period = 1 / Double(2 * mains)
        guard s >= period * 0.75 else { return s }
        let k = max(1, (s / period).rounded())
        return min(k * period, safeShutter(mains: mains, longest: longest))
    }
}
