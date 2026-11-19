import CoreGraphics

/// Geometry of the picture: rotation between sensor and picture coordinates, and the 16:9 crop window.
/// All coordinates are normalized 0…1 with a top-left origin.
public enum FrameMath {
    /// Sensor coordinates → picture coordinates as shown (inverse of `toSensor`).
    public static func toDisplay(_ p: CGPoint, rotation r: Int) -> CGPoint {
        switch r {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    /// Picture coordinates (as shown, after rotation) → unrotated sensor coordinates.
    public static func toSensor(u: Double, v: Double, rotation r: Int) -> CGPoint {
        switch r {
        case 90: return CGPoint(x: v, y: 1 - u)
        case 180: return CGPoint(x: 1 - u, y: 1 - v)
        case 270: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    /// Crop size (sensor-normalized) for a 16:9 landscape picture: the whole sensor when the picture is
    /// landscape (rotation 0/180); a landscape band across the tall frame when the phone is upright (90/270).
    /// `a` = sensor height / width.
    public static func windowSize(rotation: Int, zoom: Double, sensorAspect a: Double) -> (w: Double, h: Double) {
        let r = 16.0 / 9
        if rotation == 90 || rotation == 270 {
            // Shown width = sensor height, shown height = sensor width.
            return (w: min(1, a / r) / zoom, h: min(1, r / a) / zoom)
        }
        return (w: min(1, r * a) / zoom, h: min(1, 1 / (r * a)) / zoom)
    }

    /// Quality slider (0.4…0.95) → HEVC bitrate, 4…24 Mbit/s.
    public static func bitrate(quality q: Double) -> Int {
        let t: Double = (min(0.95, max(0.4, q)) - 0.4) / 0.55
        let mbps: Double = 4 + t * 20
        return Int((mbps * 1_000_000).rounded())
    }
}
