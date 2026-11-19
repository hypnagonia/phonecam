import Foundation

/// Picture rotation from gravity: which way the phone is mounted (0/90/180/270).
/// A new rotation is taken only after `needed` clear samples in a row (~1 s at 10 Hz); a sample between two
/// positions or a bump restarts the count, and never switches the picture by itself.
public struct OrientationTracker {
    public let needed: Int
    public private(set) var candidate = -1
    public private(set) var stable = 0

    public init(needed: Int = 10) { self.needed = needed }

    /// `phi` = atan2(gravity.y, gravity.x). Returns the rotation once it has held long enough, else nil.
    public mutating func update(phi: Double) -> Int? {
        let clear = abs(Level.deviation(phi: phi)) < .pi / 6 // within 30° of a position
        let cand = OrientationTracker.rotation(phi: phi)
        if clear, cand == candidate {
            stable += 1
        } else {
            candidate = clear ? cand : -1
            stable = 0
        }
        return stable >= needed && candidate >= 0 ? candidate : nil
    }

    /// The sensor image is upright when gravity points along -x (phi 180°), so the picture needs turning by
    /// phi + 180°, rounded to 90°.
    public static func rotation(phi: Double) -> Int {
        let deg = phi * 180 / .pi
        var r = Int(((deg + 180) / 90).rounded()) * 90 % 360
        if r < 0 { r += 360 }
        return r
    }
}

/// Horizon levelling: the roll of the phone and the picture turn that undoes it.
public enum Level {
    /// Below this nobody sees the tilt, and the frame isn't resampled.
    public static let deadZone = 0.5 * .pi / 180
    /// Larger tilts are not corrected (the phone is meant to be turned, not tilted).
    public static let maxTilt = Double.pi / 12

    /// Deviation of `phi` from the nearest multiple of 90°, in -45°…45°.
    public static func deviation(phi: Double) -> Double {
        let quarter = Double.pi / 2
        return phi - (phi / quarter).rounded() * quarter
    }

    /// The roll to correct for this gravity angle, clamped to ±`maxTilt`.
    public static func roll(phi: Double) -> Double {
        min(maxTilt, max(-maxTilt, deviation(phi: phi)))
    }

    /// Picture turn for a smoothed `tilt`: 0 inside the dead zone, then only the part past it, so the turn
    /// (and its zoom) grows from zero instead of jumping when the tilt crosses the dead zone.
    public static func correction(tilt: Double) -> Double {
        guard abs(tilt) > deadZone else { return 0 }
        return -(tilt - (tilt > 0 ? deadZone : -deadZone))
    }

    /// Zoom that hides the corners when a `width`×`height` picture is turned by `angle`.
    public static func zoom(width w: Double, height h: Double, angle a: Double) -> Double {
        let c = abs(cos(a)), s = abs(sin(a))
        return max((w * c + h * s) / w, (w * s + h * c) / h)
    }
}
