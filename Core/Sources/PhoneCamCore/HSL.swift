import Foundation
import simd

/// Per-colour Hue, Saturation and Luminance, like Lightroom or InShot: eight colours, each with three
/// adjustments from -1 to 1. A pixel between two colours gets a smooth mix of both; greys never change.
public struct HSL: Equatable {
    public static let names = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    /// Hue of each colour (sRGB HSV degrees).
    public static let centers: [Double] = [0, 30, 60, 120, 180, 220, 270, 310]

    public var hue = [Double](repeating: 0, count: 8)   // -1…1 → ±30°
    public var sat = [Double](repeating: 0, count: 8)   // -1 (grey) … +1 (twice the colour)
    public var lum = [Double](repeating: 0, count: 8)   // -1 darker … +1 lighter

    public init() {}

    public var isNeutral: Bool { (hue + sat + lum).allSatisfy { abs($0) < 0.005 } }

    /// "h,s,l;h,s,l;…" for the eight colours in `names` order. Empty or unreadable → neutral.
    public init(string: String) {
        let groups = string.split(separator: ";")
        for (i, g) in groups.prefix(8).enumerated() {
            let v = g.split(separator: ",").map { Double($0) ?? 0 }
            guard v.count == 3 else { continue }
            hue[i] = min(1, max(-1, v[0])); sat[i] = min(1, max(-1, v[1])); lum[i] = min(1, max(-1, v[2]))
        }
    }

    public var string: String {
        func f(_ x: Double) -> String { let r = (x * 100).rounded() / 100; return r == 0 ? "0" : String(r) }
        return (0..<8).map { "\(f(hue[$0])),\(f(sat[$0])),\(f(lum[$0]))" }.joined(separator: ";")
    }

    /// The old Red / Green / Blue saturation sliders (0…1.5, 1 = unchanged) as HSL saturation.
    public static func fromOldSliders(red: Double, green: Double, blue: Double) -> HSL {
        var h = HSL()
        func s(_ k: Double) -> Double { min(1, max(-1, k - 1)) }
        h.sat[0] = s(red); h.sat[1] = s(red)
        h.sat[3] = s(green)
        h.sat[4] = s(blue); h.sat[5] = s(blue)
        return h
    }

    /// The two colours a hue sits between and how far it is from the first (0…1, eased).
    static func between(_ h: Double) -> (Int, Int, Double) {
        for i in 0..<8 {
            let a = centers[i], b = i == 7 ? centers[0] + 360 : centers[i + 1]
            let x = h < a ? h + 360 : h
            if x >= a && x < b {
                let t = (x - a) / (b - a)
                return (i, (i + 1) % 8, 0.5 - 0.5 * cos(.pi * t))
            }
        }
        return (0, 1, 0)
    }

    /// The adjustment for a hue: (hue shift in degrees, saturation factor - 1, luminance -1…1).
    public func adjustment(hue h: Double) -> (dh: Double, ds: Double, dl: Double) {
        let (a, b, t) = HSL.between(h)
        func mix(_ v: [Double]) -> Double { v[a] * (1 - t) + v[b] * t }
        return (mix(hue) * 30, mix(sat), mix(lum))
    }
}

/// The 32³ colour cube the picture goes through (gamma-encoded sRGB in and out): HSL per colour, skin kept
/// at its natural saturation when the global saturation changes, and the Skin white balance's hue shift.
public enum ColorCube {
    public static let size = 32

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    /// HSV hue in degrees (0…360); nil when max − min ≤ `minChroma` (near grey).
    public static func hue(_ c: SIMD3<Double>, minChroma: Double = 0.0001) -> Double? {
        let mx = max(c.x, c.y, c.z), d = mx - min(c.x, c.y, c.z)
        guard d > minChroma else { return nil }
        var h: Double
        if mx == c.x { h = 60 * ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
        else { h = 60 * ((c.x - c.y) / d + 4) }
        return h < 0 ? h + 360 : h
    }

    /// The same HSV saturation and value at a new hue.
    static func withHue(_ c: SIMD3<Double>, _ nh: Double) -> SIMD3<Double> {
        let v = max(c.x, c.y, c.z), chroma = v - min(c.x, c.y, c.z)
        var h = nh.truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
        let hp = h / 60, x = chroma * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = v - chroma
        let t: SIMD3<Double>
        switch Int(hp) {
        case 0: t = SIMD3(chroma, x, 0)
        case 1: t = SIMD3(x, chroma, 0)
        case 2: t = SIMD3(0, chroma, x)
        case 3: t = SIMD3(0, x, chroma)
        case 4: t = SIMD3(x, 0, chroma)
        default: t = SIMD3(chroma, 0, x)
        }
        return t + SIMD3(repeating: m)
    }

    /// Weight of a narrow (±30°) band around `center`.
    static func band30(_ h: Double, _ center: Double) -> Double {
        var d = abs(h - center).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d >= 30 ? 0 : 0.5 + 0.5 * cos(.pi * d / 30)
    }

    /// One colour through the cube's adjustments.
    public static func apply(_ c0: SIMD3<Double>, hsl: HSL, saturation: Double, skinCenter: Double, skinShift: Double,
                             tone: AutoOperator.Tone = AutoOperator.Tone()) -> SIMD3<Double> {
        var c = c0
        if let h = hue(c) {
            let mx = max(c.x, c.y, c.z), chroma = mx - min(c.x, c.y, c.z)
            let colourful = smoothstep(0.02, 0.12, chroma) // greys and near-greys stay as they are
            let a = hsl.adjustment(hue: h)
            if abs(a.dh) > 0.01 { c = c + (withHue(c, h + a.dh) - c) * colourful }
            // Saturation: the colour scaled around the grey of the same luma; skin (~25°) also keeps its
            // natural saturation whatever the global saturation slider does.
            var f = 1 + a.ds * colourful
            f *= 1 + (1 / max(0.3, saturation) - 1) * band30(h, 25)
            if abs(f - 1) > 0.0001 {
                let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                c = SIMD3(repeating: y) + (c - SIMD3(repeating: y)) * f
            }
            // Luminance: lighter or darker, more so the more colourful the pixel is.
            if abs(a.dl) > 0.005 {
                let k = 1 + 0.45 * a.dl * colourful * min(1, chroma / max(mx, 1e-6) * 1.5)
                c = c * k
            }
        }
        if abs(skinShift) > 0.25 {
            // Skin white balance: turn the hue of skin tones (±30° around the face's hue) by skinShift.
            let x = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
            if let h = hue(x) {
                let w = band30(h, skinCenter)
                if w > 0 { c = withHue(x, h + skinShift * w) }
            }
        }
        c = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        if !tone.isNeutral { c = SIMD3(tone.map(c.x), tone.map(c.y), tone.map(c.z)) }
        return c
    }

    /// CIColorCube data (RGBA Float32); nil when the cube would change nothing.
    public static func make(hsl: HSL, saturation: Double, skinCenter: Double, skinShift: Double,
                            tone: AutoOperator.Tone = AutoOperator.Tone()) -> Data? {
        guard !(hsl.isNeutral && abs(saturation - 1) < 0.01 && abs(skinShift) < 0.25 && tone.isNeutral) else { return nil }
        return CubeLUT.make(size: size) {
            apply($0, hsl: hsl, saturation: saturation, skinCenter: skinCenter, skinShift: skinShift, tone: tone)
        }.cubeData(amount: 1)
    }
}
