import CoreGraphics
import Foundation

/// HSL auto 2 ("portrait"): you stand out from the room. Looks at two parts of the picture separately, the
/// clothes (below the face) and the background (away from the person), and asks the colour cube for:
///  - clothes: their main colours richer, and turned toward the nearest clean hue (`anchors`), at most 12°;
///  - one accent in the background, if there is one (a small, clearly coloured thing: a lamp, a poster): richer;
///  - big coloured background surfaces that are neither: a little calmer, so the person reads first.
/// Skin is handled by the cube's tan (`ColorCube` skinTan), never by these bands. The cube is global (a hue is
/// changed everywhere), so this works through the colours the clothes and the background don't share.
public enum Portrait {
    /// Clean, pleasant hues clothes are turned toward (sRGB HSV degrees). 48° is golden / olive: an olive sweater
    /// the camera sees warmer (~34°) goes back toward its own colour. No orange anchor: that is skin's hue.
    public static let anchors: [Double] = [355, 48, 140, 178, 212, 262, 322]
    /// Largest hue turn for clothes.
    public static let maxTurn = 12.0

    public struct Stats: Equatable {
        public var clothes = [Double](repeating: 0, count: 8)       // share of the clothes area per colour
        public var clothesChroma = [Double](repeating: 0, count: 8)
        public var clothesHue = [Double](repeating: 0, count: 8)    // mean hue of those pixels (degrees)
        public var background = [Double](repeating: 0, count: 8)    // share of the background per colour
        public var backgroundChroma = [Double](repeating: 0, count: 8)
        public var hasPerson = false
        public init() {}
    }

    public struct Target: Equatable {
        public var hue = [Double](repeating: 0, count: 8)  // HSL hue units (1 = 30°)
        public var sat = [Double](repeating: 0, count: 8)
        public init() {}
    }

    /// Hues within 10° of the face's own hue are left out of the clothes: hands and neck aren't clothes. (A wide
    /// fixed "skin" range would also swallow brown, olive and beige clothes, which sit 15–30° from real skin.)
    static func skinLike(_ h: Double, skinHue: Double) -> Bool { abs(angle(h - skinHue)) < 10 }

    /// A sensor-normalized rect in picture coordinates (as shown, after `rotation`).
    static func shown(_ r: CGRect, rotation: Int) -> CGRect {
        let a = FrameMath.toDisplay(CGPoint(x: r.minX, y: r.minY), rotation: rotation)
        let b = FrameMath.toDisplay(CGPoint(x: r.maxX, y: r.maxY), rotation: rotation)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Analyse an RGBA8 frame from the sensor (gamma-encoded sRGB, top row first). `window`: the part the stream
    /// shows; `face`: the face box; both sensor-normalized, top-left origin. `rotation`: how the sensor frame is
    /// turned to make the picture, so "below the face" means below in the picture, wherever the phone points.
    public static func analyze(rgba px: [UInt8], width w: Int, height h: Int, window sensorWindow: CGRect,
                               face sensorFace: CGRect?, rotation: Int = 0, skinHue: Double = 20) -> Stats {
        let window = shown(sensorWindow, rotation: rotation)
        let face = sensorFace.map { shown($0, rotation: rotation) }
        var clothesBox: CGRect?, personBox: CGRect?
        if let f = face {
            clothesBox = CGRect(x: f.midX - f.width * 1.3, y: f.maxY + f.height * 0.45,
                                width: f.width * 2.6, height: max(0, window.maxY - (f.maxY + f.height * 0.45)))
            personBox = CGRect(x: f.minX - f.width * 1.4, y: f.minY - f.height * 0.7,
                               width: f.width * 3.8, height: 2)
        }
        var cc = [Double](repeating: 0, count: 8), cch = [Double](repeating: 0, count: 8)
        var cx = [Double](repeating: 0, count: 8), cy = [Double](repeating: 0, count: 8)
        var bc = [Double](repeating: 0, count: 8), bch = [Double](repeating: 0, count: 8)
        var clothesTotal = 0.0, bgTotal = 0.0
        for row in 0..<h {
            for col in 0..<w {
                let p = FrameMath.toDisplay(CGPoint(x: (Double(col) + 0.5) / Double(w), y: (Double(row) + 0.5) / Double(h)),
                                            rotation: rotation)
                guard window.contains(p) else { continue }
                let inClothes = clothesBox?.contains(p) ?? false
                let inPerson = personBox?.contains(p) ?? false
                if inClothes { clothesTotal += 1 } else if !inPerson { bgTotal += 1 } else { continue }
                let i = (row * w + col) * 4
                let c = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
                let mx = max(c.x, c.y, c.z), chroma = mx - min(c.x, c.y, c.z)
                guard chroma >= 0.12, mx >= 0.12, let hue = ColorCube.hue(c) else { continue }
                let (a, b, t) = HSL.between(hue)
                if inClothes {
                    if skinLike(hue, skinHue: skinHue) { continue }
                    let rad = hue * .pi / 180
                    for (k, wt) in [(a, 1 - t), (b, t)] {
                        cc[k] += wt; cch[k] += wt * chroma
                        cx[k] += wt * cos(rad); cy[k] += wt * sin(rad)
                    }
                } else {
                    bc[a] += 1 - t; bc[b] += t
                    bch[a] += (1 - t) * chroma; bch[b] += t * chroma
                }
            }
        }
        var s = Stats()
        s.hasPerson = face != nil && clothesTotal > 0
        for i in 0..<8 {
            if clothesTotal > 0 {
                s.clothes[i] = cc[i] / clothesTotal
                s.clothesChroma[i] = cc[i] > 0 ? cch[i] / cc[i] : 0
                var mean = atan2(cy[i], cx[i]) * 180 / .pi
                if mean < 0 { mean += 360 }
                s.clothesHue[i] = cc[i] > 0 ? mean : HSL.centers[i]
            }
            if bgTotal > 0 {
                s.background[i] = bc[i] / bgTotal
                s.backgroundChroma[i] = bc[i] > 0 ? bch[i] / bc[i] : 0
            }
        }
        return s
    }

    static func ramp(_ a: Double, _ b: Double, _ x: Double) -> Double { min(1, max(0, (x - a) / (b - a))) }

    /// Signed difference of two hue angles, -180…180.
    static func angle(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    /// The turn (degrees) that brings `hue` toward the nearest clean anchor, at most `maxTurn`.
    public static func turnToClean(_ hue: Double) -> Double {
        let d = anchors.map { angle($0 - hue) }.min { abs($0) < abs($1) } ?? 0
        return min(maxTurn, max(-maxTurn, d))
    }

    /// What the cube should do for one look at the scene, at `strength` 0…1 (before smoothing).
    public static func target(_ s: Stats, strength k: Double) -> Target {
        var t = Target()
        var clothesBands = Set<Int>()
        if s.hasPerson {
            // orange too (brown, olive, camel clothes): the cube keeps skin itself out of the bands
            for i in 0..<8 where s.clothes[i] >= 0.08 {
                clothesBands.insert(i)
                let juicy = ramp(0.08, 0.2, s.clothes[i])
                // paler clothes gain more, already vivid ones a little (no neon)
                t.sat[i] += k * juicy * (0.1 + min(0.3, 0.5 * (1 - s.clothesChroma[i])))
                t.hue[i] += k * juicy * turnToClean(s.clothesHue[i]) / 30
            }
        }
        // The accent: the most noticeable *small*, clearly coloured thing in the background (a lamp, a poster),
        // not a clothes colour, not skin. There may be none: then nothing is picked (a wall never becomes one).
        var best = -1, bestScore = 0.0
        for i in 0..<8 where i != 1 && !clothesBands.contains(i) {
            let cov = s.background[i], chroma = s.backgroundChroma[i]
            // a big surface between two colours spills a little into the neighbouring band: that sliver isn't
            // a small object, so a neighbour with a big share rules the band out
            let neighbours = max(s.background[(i + 7) % 8], s.background[(i + 1) % 8])
            let score = ramp(0.002, 0.005, cov) * (1 - ramp(0.04, 0.06, cov)) * ramp(0.25, 0.35, chroma)
                * (1 - ramp(0.04, 0.08, neighbours))
            if score > bestScore { bestScore = score; best = i }
        }
        if best >= 0 { t.sat[best] += k * 0.35 * (1 - 0.5 * s.backgroundChroma[best]) }
        // big background colours that are neither: a little calmer, so the person reads first
        for i in 0..<8 where i != best && !clothesBands.contains(i) && i != 1 {
            t.sat[i] -= k * 0.18 * ramp(0.06, 0.2, s.background[i])
        }
        for i in 0..<8 { t.sat[i] = min(1, max(-1, t.sat[i])); t.hue[i] = min(1, max(-1, t.hue[i])) }
        return t
    }
}
