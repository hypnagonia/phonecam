import Foundation

/// PhoneCam's own looks, made in code (no third-party LUTs in the repository). They work on gamma-encoded
/// Rec.709/sRGB video like any "Rec709" .cube file, and are meant to be used at 40–80% strength.
public enum Looks {
    public static let names = ["Film", "Warm", "Matte", "Teal & Orange", "Mono"]

    public static func lut(_ name: String, size: Int = 33) -> CubeLUT? {
        guard let f = function(name) else { return nil }
        return CubeLUT.make(size: size, f)
    }

    static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// Saturation around the grey of the same luma (brightness stays).
    static func saturate(_ c: SIMD3<Double>, _ s: Double) -> SIMD3<Double> {
        let y = luma(c)
        return SIMD3(repeating: y) + (c - SIMD3(repeating: y)) * s
    }

    /// Gentle S-curve: k = 0 straight, k > 0 more contrast around mid grey, ends stay at 0 and 1.
    static func sCurve(_ x: Double, _ k: Double) -> Double {
        let s = x * x * (3 - 2 * x) // smoothstep
        return x + (s - x) * k
    }

    static func curve(_ c: SIMD3<Double>, _ k: Double) -> SIMD3<Double> { SIMD3(sCurve(c.x, k), sCurve(c.y, k), sCurve(c.z, k)) }

    /// Black and white points: 0 → lo, 1 → hi.
    static func range(_ c: SIMD3<Double>, _ lo: Double, _ hi: Double) -> SIMD3<Double> { SIMD3(repeating: lo) + c * (hi - lo) }

    /// Split toning: `shadows` tint where the picture is dark, `highlights` where it is bright.
    static func split(_ c: SIMD3<Double>, shadows: SIMD3<Double>, highlights: SIMD3<Double>) -> SIMD3<Double> {
        let y = min(1, max(0, luma(c)))
        let ws = (1 - y) * (1 - y), wh = y * y
        return c + shadows * ws + highlights * wh
    }

    static func function(_ name: String) -> ((SIMD3<Double>) -> SIMD3<Double>)? {
        switch name {
        case "Film":
            // Soft print-film feel: a little contrast, lifted blacks, rolled-off whites, cool shadows and
            // warm highlights, slightly less saturation.
            return { c in
                var x = curve(c, 0.3)
                x = range(x, 0.04, 0.96)
                x = split(x, shadows: SIMD3(-0.02, 0.006, 0.035), highlights: SIMD3(0.035, 0.01, -0.045))
                return saturate(x, 0.88)
            }
        case "Warm":
            // Golden-hour warmth, a touch more colour, soft contrast.
            return { c in
                var x = SIMD3(c.x * 1.045, c.y * 1.0, c.z * 0.93)
                x *= luma(c) / max(1e-6, luma(x)) // same brightness
                x = curve(x, 0.15)
                return saturate(range(x, 0.012, 1), 1.06)
            }
        case "Matte":
            // Faded, low-contrast look: blacks lifted to dark grey, whites slightly dimmed, muted colour.
            return { c in
                var x = curve(c, -0.1)
                x = range(x, 0.075, 0.95)
                x = split(x, shadows: SIMD3(-0.006, 0.0, 0.012), highlights: SIMD3(0.008, 0.004, -0.006))
                return saturate(x, 0.82)
            }
        case "Teal & Orange":
            // Cinema blockbuster: shadows and cool colours toward teal, skin and highlights toward orange.
            return { c in
                var x = curve(c, 0.25)
                x = split(x, shadows: SIMD3(-0.05, 0.015, 0.06), highlights: SIMD3(0.05, 0.012, -0.06))
                return saturate(x, 1.1)
            }
        case "Mono":
            // Black and white with a little contrast and a hint of warmth in the highlights.
            return { c in
                let y = sCurve(min(1, max(0, luma(c))), 0.3)
                let g = 0.015 + y * 0.975
                return SIMD3(g + 0.006 * y, g, g - 0.008 * y)
            }
        default:
            return nil
        }
    }
}
