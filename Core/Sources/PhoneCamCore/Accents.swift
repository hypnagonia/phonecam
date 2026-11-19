import Foundation
import CoreGraphics

/// Auto accents: find the colours in the background, from small things (a blue lamp, an LED strip, a poster)
/// to a coloured light washing a wall, and make them a little richer; tame only a huge, already acid colour;
/// never touch skin. Decided slowly from many looks at the scene, so the picture never jumps.
public enum Accents {
    /// What one look at the scene found: per HSL colour, its share of the background and its mean chroma.
    public struct Stats: Equatable {
        public var coverage = [Double](repeating: 0, count: 8) // 0…1 of the analysed background
        public var chroma = [Double](repeating: 0, count: 8)   // mean HSV chroma of those pixels, 0…1
        public init() {}
    }

    /// Analyse an RGBA8 picture (gamma-encoded sRGB, top row first). `window`: the part the stream shows,
    /// `face`: the face box (both normalized, top-left origin); the face, hair and neck are left out.
    public static func analyze(rgba px: [UInt8], width w: Int, height h: Int, window: CGRect, face: CGRect?) -> Stats {
        var exclude: CGRect?
        if let f = face {
            exclude = CGRect(x: f.minX - f.width * 0.35, y: f.minY - f.height * 0.5,
                             width: f.width * 1.7, height: f.height * 2.3)
        }
        var cov = [Double](repeating: 0, count: 8), chr = [Double](repeating: 0, count: 8)
        var total = 0.0
        for row in 0..<h {
            let y = (Double(row) + 0.5) / Double(h)
            guard y >= window.minY, y <= window.maxY else { continue }
            for col in 0..<w {
                let x = (Double(col) + 0.5) / Double(w)
                guard x >= window.minX, x <= window.maxX else { continue }
                if let e = exclude, e.contains(CGPoint(x: x, y: y)) { continue }
                total += 1
                let i = (row * w + col) * 4
                let c = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
                let mx = max(c.x, c.y, c.z), chroma = mx - min(c.x, c.y, c.z)
                guard chroma >= 0.12, mx >= 0.12, let hue = ColorCube.hue(c) else { continue }
                let (a, b, t) = HSL.between(hue)
                cov[a] += 1 - t; cov[b] += t
                chr[a] += (1 - t) * chroma; chr[b] += t * chroma
            }
        }
        var s = Stats()
        guard total > 0 else { return s }
        for i in 0..<8 {
            s.coverage[i] = cov[i] / total
            s.chroma[i] = cov[i] > 0 ? chr[i] / cov[i] : 0
        }
        return s
    }

    static func ramp(_ a: Double, _ b: Double, _ x: Double) -> Double { min(1, max(0, (x - a) / (b - a))) }

    /// Saturation change per colour for one look at the scene (before smoothing), at `strength` 0…1.
    public static func target(_ s: Stats, strength k: Double, faceInView: Bool) -> [Double] {
        (0..<8).map { i in
            let cov = s.coverage[i], chroma = s.chroma[i]
            // Red and orange are skin tones: never made richer, even while nobody is in the picture (a boost
            // learned on an empty room would land on the face when you sit down again).
            let skin = i == 0 || i == 1
            // A colour in the background: from 0.2 % of it (fully from 0.5 %) up to a coloured light on a
            // wall (fading out from 30 % to 50 %: then it is the room itself, not an accent).
            let accent = skin ? 0 : ramp(0.002, 0.005, cov) * (1 - ramp(0.3, 0.5, cov))
            // Paler colours gain more, already vivid ones only a little (no neon); big areas a bit less
            // than small ones, so a coloured wall glows rather than shouts.
            let size = 1 - 0.35 * ramp(0.1, 0.3, cov)
            let boost = accent * size * min(0.45, 0.6 * (1 - chroma))
            // A huge, already acid colour (more than a third of the picture): a little calmer.
            let calm = 0.2 * ramp(0.35, 0.5, cov) * ramp(0.5, 0.65, chroma)
            return k * (boost - calm)
        }
    }

    /// Smooths the targets over time: the median of the last ~30 s of looks, approached slowly, so a
    /// passing object or a blinking light changes nothing and the look never jumps.
    public struct Tracker {
        public private(set) var value = [Double](repeating: 0, count: 8)
        private var history: [[Double]] = []
        public let length: Int, rate: Double

        public init(length: Int = 15, rate: Double = 0.08) { self.length = length; self.rate = rate }

        public mutating func update(_ target: [Double]) -> [Double] {
            history.append(target)
            if history.count > length { history.removeFirst(history.count - length) }
            for i in 0..<8 {
                let v = history.map { $0[i] }.sorted()
                let median = v[v.count / 2]
                value[i] += (median - value[i]) * rate
                if abs(value[i]) < 0.002 { value[i] = 0 }
            }
            return value
        }

        public mutating func reset() { value = [Double](repeating: 0, count: 8); history = [] }
    }
}

extension HSL {
    /// This HSL with `sat` added to each colour's saturation (clamped).
    public func addingSaturation(_ add: [Double]) -> HSL {
        var h = self
        for i in 0..<8 { h.sat[i] = min(1, max(-1, h.sat[i] + add[i])) }
        return h
    }
}
