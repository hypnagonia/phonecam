import Foundation
import CoreGraphics

/// "Auto operator": cheap, slow, face-aware helpers that make the auto picture steadier and more polished.
public enum AutoOperator {

    // MARK: steady auto

    /// Holds auto exposure (or white balance) while the light doesn't really change, so moving a hand or
    /// leaning in doesn't make the picture breathe; lets auto run again when it does change. Fed once a second
    /// with how far the camera's meter is from its target (EV, or relative white balance difference).
    public struct Hold: Equatable {
        public enum Action: Equatable { case hold, release }
        public private(set) var held = false
        var calm = 0, off = 0
        public let settle: Double, change: Double, seconds: Int

        public init(settle: Double, change: Double, seconds: Int = 2) {
            self.settle = settle; self.change = change; self.seconds = seconds
        }

        public mutating func step(_ distance: Double) -> Action? {
            let d = abs(distance)
            if held {
                off = d > change ? off + 1 : 0
                if off >= seconds { held = false; off = 0; calm = 0; return .release }
            } else {
                calm = d < settle ? calm + 1 : 0
                if calm >= seconds { held = true; calm = 0; off = 0; return .hold }
            }
            return nil
        }

        public mutating func reset() { held = false; calm = 0; off = 0 }
    }

    // MARK: face light and vignette

    /// One radial gain: `face` (≥ 1) at the face, falling to `edge` (≤ 1) toward the corners.
    public struct Light: Equatable {
        public var center: CGPoint   // picture pixels, top-left origin
        public var radius0: Double   // full face gain inside this
        public var radius1: Double   // edge gain from here on
        public var face: Double
        public var edge: Double
    }

    /// The gain for a picture of `size` with the face at `faceCenter` (picture-normalized, top-left origin;
    /// nil = no face: just the vignette around the middle) of `faceSize` (fraction of the picture height).
    /// `faceLuma` (0…1, sRGB): a dark face gets a little more light, a bright one none.
    public static func light(size: CGSize, faceCenter: CGPoint?, faceSize: Double, faceLuma: Double?, strength k: Double) -> Light {
        let c = faceCenter ?? CGPoint(x: 0.5, y: 0.45)
        let diag = Double(hypot(size.width, size.height))
        let r0 = max(0.08, faceSize) * Double(size.height) * 0.9
        let need = faceLuma.map { min(1, max(0, (0.55 - $0) / 0.25)) } ?? 0.5 // 0 when the face is bright enough
        let lift = faceCenter == nil ? 0 : 0.08 * k * (0.35 + 0.65 * need)
        return Light(center: CGPoint(x: c.x * size.width, y: c.y * size.height),
                     radius0: r0, radius1: max(r0 * 1.5, diag * 0.62), face: 1 + lift, edge: 1 - 0.16 * k)
    }

    // MARK: auto tone

    /// A gentle tone correction from the brightness histogram: a flat picture gets contrast, a dark one
    /// brighter mid-tones. Small on purpose: it polishes, it doesn't restyle.
    public struct Tone: Equatable {
        public var contrast = 0.0   // 0…0.15: S-curve strength
        public var mids = 0.0       // -0.1…0.15: + brighter mid-tones
        public var black = 0.0      // 0…0.14: the black point. What is darkest in the picture but still grey (haze from
                                    // a window behind you, a lifted exposure) becomes black
        public var white = 0.0      // 0…0.08: the white point. What is brightest but short of white becomes white
        public init() {}
        public var isNeutral: Bool { abs(contrast) < 0.005 && abs(mids) < 0.005 && black < 0.003 && white < 0.003 }

        /// The curve for one channel value (gamma-encoded 0…1): the tones between `black` and `1 − white` are spread
        /// over the whole range, and the two ends are rounded off (a toe and a shoulder half as wide as the point
        /// moved), so shadows sink into black and highlights rise into white instead of being cut at a hard edge.
        public func map(_ x: Double) -> Double {
            var y = x
            if black > 0 || white > 0 {
                y = (x - black) / (1 - black - white)
                let toe = min(0.08, black * 0.5), sh = min(0.06, white * 0.5)
                if toe > 0, y < toe { y = y <= -toe ? 0 : (y + toe) * (y + toe) / (4 * toe) }
                if sh > 0, y > 1 - sh { y = y >= 1 + sh ? 1 : 1 - (1 + sh - y) * (1 + sh - y) / (4 * sh) }
                y = min(1, max(0, y))
            }
            y += mids * 2 * y * (1 - y)                      // mid-tones up or down
            let s = y * y * (3 - 2 * y)
            y += (s - y) * contrast * 2                      // S-curve
            return min(1, max(0, y))
        }

        /// The curve at five points (input, output), for tests and display.
        public var points: [(Double, Double)] { [0, 0.25, 0.5, 0.75, 1].map { ($0, map($0)) } }
    }

    /// The tone for a 64-bin luma histogram (sRGB-encoded luma, counts), at `strength` 0…1.
    public static func tone(histogram h: [Double], strength k: Double) -> Tone {
        let total = h.reduce(0, +)
        var t = Tone()
        guard total > 0 else { return t }
        func percentile(_ p: Double) -> Double {
            var acc = 0.0
            for (i, v) in h.enumerated() { acc += v; if acc >= p * total { return (Double(i) + 0.5) / Double(h.count) } }
            return 1
        }
        let lo = percentile(0.02), hi = percentile(0.98), mid = percentile(0.5), darkest = percentile(0.01)
        let span = hi - lo
        t.contrast = k * min(0.15, max(0, (0.75 - span) * 0.35))      // flat → a little more contrast
        // Dark → brighter mid-tones; very bright → a little darker; a normal picture is left alone.
        let m = mid < 0.42 ? (0.42 - mid) * 0.6 : (mid > 0.62 ? (0.62 - mid) * 0.5 : 0)
        t.mids = k * min(0.15, max(-0.1, m))
        // The points, on purpose not all the way: the darkest 1 % still grey goes 70 % of the way to a deep (not
        // dead) black at 4 %, by at most 0.14; the brightest half per cent goes 60 % of the way to 96 %, by at most
        // 0.08. Taken all the way (2 % and 98 %) the picture was hard: shadows blocked up, the wall behind burnt.
        // The caps also keep a dim evening room from being stretched into day.
        t.black = k * min(0.14, max(0, (darkest - 0.04) * 0.7))
        t.white = k * min(0.08, max(0, (0.96 - percentile(0.995)) * 0.6))
        return t
    }

    /// Slow, stable tone: median of the last looks, approached gradually (same idea as Accents.Tracker).
    public struct ToneTracker {
        public private(set) var tone = Tone()
        var history: [Tone] = []
        public init() {}
        public mutating func update(_ t: Tone) -> Tone {
            history.append(t)
            if history.count > 15 { history.removeFirst() }
            let c = history.map(\.contrast).sorted()[history.count / 2]
            let m = history.map(\.mids).sorted()[history.count / 2]
            let b = history.map(\.black).sorted()[history.count / 2]
            let w = history.map(\.white).sorted()[history.count / 2]
            tone.contrast += (c - tone.contrast) * 0.08
            tone.mids += (m - tone.mids) * 0.08
            // the points faster than the curve: a haze over the whole picture is plain to see while it lasts
            tone.black += (b - tone.black) * 0.25
            tone.white += (w - tone.white) * 0.25
            return tone
        }
        public mutating func reset() { tone = Tone(); history = [] }
    }
}
