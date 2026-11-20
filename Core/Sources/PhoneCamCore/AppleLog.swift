import Foundation

/// Apple Log video (iPhone 15 Pro and later) → a finished Rec.709 picture.
///
/// In Apple Log the iPhone does almost none of its own picture processing: no HDR merging, no lifted shadows,
/// little sharpening; the frames hold the scene's light (about 12 times diffuse white) in a logarithmic code,
/// in Rec.2020 colours. Shown as they are they look grey and flat, and so does the scene's light put on a
/// screen one to one. `develop` does what a camera does between its sensor and Rec.709, and no more:
///  1. the log code → linear light;
///  2. Rec.2020 → Rec.709, with colours outside Rec.709 eased in instead of cut off (a cut turns them into
///     flat patches of another hue);
///  3. the exposure;
///  4. the contrast a screen needs (Rec.709's own rendering: a power of about 1.2 on each channel around the
///     middle; it is what makes colours full, and without it every camera looks washed out);
///  5. highlights, up to the brightest the frame holds, fitted under white by brightness, with the colour kept until it is nearly white (done channel
///     by channel, bright skin and coloured lights go pale and yellow).
public enum AppleLog {
    // The constants of Apple's published curve.
    static let r0 = -0.05641088, rt = 0.01, c = 47.28711236, beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
    static let pt = c * (rt - r0) * (rt - r0)

    /// Code value (0…1) → scene light (0.18 = mid grey).
    public static func decode(_ p: Double) -> Double {
        if p >= pt { return pow(2, (p - delta) / gamma) - beta }
        if p >= 0 { return (p / c).squareRoot() + r0 }
        return r0
    }

    /// Scene light → code value.
    public static func encode(_ r: Double) -> Double {
        if r >= rt { return gamma * log2(r + beta) + delta }
        if r >= r0 { return c * (r - r0) * (r - r0) }
        return 0
    }

    /// Linear Rec.2020 → linear Rec.709/sRGB.
    public static func toRec709(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(1.6605 * v.x - 0.5876 * v.y - 0.0728 * v.z,
              -0.1246 * v.x + 1.1329 * v.y - 0.0083 * v.z,
              -0.0182 * v.x - 0.1006 * v.y + 1.1187 * v.z)
    }

    /// The exposure the camera's frames are developed with. The iPhone exposes Apple Log well under its normal
    /// video (to keep highlights): on the same scene a face sat at 0.11 of scene light where normal video shows
    /// it at about 0.27 of the screen's range. 2.4 puts it there.
    public static let cameraExposure = 2.4
    static let knee = 0.5, fadeFrom = 0.75
    /// The screen contrast (step 4) and the level it turns around: a face's, so faces keep their brightness.
    static let screenGamma = 1.18
    public static let pivot = 0.27

    /// What to add to every channel's log code to make the picture `stops` brighter: on the log part of the
    /// curve a gain is an offset, so the exposure can follow the face without rebuilding the cube.
    public static func codeOffset(stops: Double) -> Double { gamma * stops }

    /// Where the face is held, before Face light adds its own: with the face at the pivot (0.27) and a window
    /// behind, the lift was +1.3 stops and the whole room burnt out. 0.20 and at most +0.8 stop keep the room.
    public static let faceTarget = 0.20, maxLift = 0.8, maxCut = -1.0

    /// The face's brightness on the screen (linear, 0…1) → how far the exposure should move, in stops, on this
    /// measurement. Nothing inside ±0.15 stop of the target (it must not breathe with every turn of the head),
    /// a small step otherwise: about 4 s for a real change at four measurements a second.
    public static func exposureStep(faceLuma: Double, target: Double = faceTarget) -> Double {
        let err = log2(target / max(0.01, faceLuma))
        guard abs(err) > 0.15 else { return 0 }
        return min(1, max(-1, err)) * 0.06
    }

    static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// Colours outside Rec.709 (a channel below zero after the matrix) brought inside. Each channel's distance
    /// from the brightest one is left alone up to 80 % of the way to the edge; beyond that it is compressed so
    /// that what lay up to 30 % outside lands on the edge (the method of the ACES reference gamut compression).
    static func intoGamut(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let top = max(c.x, c.y, c.z)
        guard top > 1e-9 else { return SIMD3(repeating: max(0, top)) }
        let t = 0.8, limit = 1.3, s = (limit - t) / ((limit - t) / (1 - t) - 1)
        func f(_ v: Double) -> Double {
            let d = (top - v) / top
            guard d > t else { return v }
            let x = d - t
            return top - (t + x / (1 + x / s)) * top
        }
        return SIMD3(max(0, f(c.x)), max(0, f(c.y)), max(0, f(c.z)))
    }

    /// The brightest light a frame can hold, after the exposure: about 29 times the screen's white.
    static let brightest = decode(1) * cameraExposure
    /// The shoulder's bend, chosen so that the curve leaves the straight line at `knee` without a kink.
    static let bend: Double = {
        var lo = 1e-4, hi = 1.0 // a·ln(1 + (brightest − knee) / a) grows with a: bisect for it to equal 1 − knee
        for _ in 0..<60 {
            let a = (lo + hi) / 2
            if a * log(1 + (brightest - knee) / a) < 1 - knee { lo = a } else { hi = a }
        }
        return (lo + hi) / 2
    }()

    /// Brightness → brightness on the screen, 0…1: a straight line up to half of the screen's range (faces, walls
    /// in shade); everything brighter, up to the brightest light the frame holds, is fitted into the upper half
    /// on a logarithmic curve. So a window behind you keeps its curtain and the view instead of being a white
    /// hole: with the short shoulder there was before, anything over about twice the screen's white was gone.
    public static func shoulder(_ x: Double) -> Double {
        if x <= knee { return max(0, x) }
        return min(1, knee + (1 - knee) * log(1 + (x - knee) / bend) / log(1 + (brightest - knee) / bend))
    }

    /// Log code RGB → linear sRGB for the screen, as a colour function for a cube.
    public static func develop(_ p: SIMD3<Double>, exposure: Double = cameraExposure) -> SIMD3<Double> {
        var c = intoGamut(toRec709(SIMD3(decode(p.x), decode(p.y), decode(p.z)))) * exposure
        func contrast(_ v: Double) -> Double { pivot * pow(max(0, v) / pivot, screenGamma) }
        c = SIMD3(contrast(c.x), contrast(c.y), contrast(c.z))
        let y = luma(c)
        guard y > 1e-9 else { return SIMD3(repeating: 0) }
        let yd = shoulder(y)
        c *= yd / y
        // from 75 % up the colour gives way to white, so nothing clips to a hard edge of flat colour
        let k = min(1, max(0, (yd - fadeFrom) / (1 - fadeFrom))), fade = k * k * (3 - 2 * k)
        c = SIMD3(repeating: yd) + (c - SIMD3(repeating: yd)) * (1 - fade)
        return SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z)))
    }

    /// CIColorCube data (size³ RGBA Float32) that develops Apple Log code values into linear sRGB.
    public static func cubeData(size: Int = 48, exposure: Double = cameraExposure) -> Data {
        CubeLUT.make(size: size) { develop($0, exposure: exposure) }.cubeData(amount: 1)
    }
}
