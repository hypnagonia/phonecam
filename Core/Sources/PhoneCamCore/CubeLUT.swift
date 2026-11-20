import Foundation

/// A 3D colour lookup table: `size`³ RGB entries, red changing fastest, then green, then blue (the order of
/// Core Image's CIColorCube). Values are for gamma-encoded Rec.709/sRGB video.
public struct CubeLUT: Equatable {
    public let size: Int
    public let rgb: [Float]      // size³ × 3, 0…1

    public init(size: Int, rgb: [Float]) {
        precondition(rgb.count == size * size * size * 3)
        self.size = size
        self.rgb = rgb
    }

    /// Identity table (output = input).
    public static func identity(size: Int) -> CubeLUT { make(size: size) { $0 } }

    /// A table from a colour function on 0…1 RGB (outputs are clamped).
    public static func make(size: Int, _ f: (SIMD3<Double>) -> SIMD3<Double>) -> CubeLUT {
        var out = [Float](); out.reserveCapacity(size * size * size * 3)
        let n = Double(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let c = f(SIMD3(Double(r) / n, Double(g) / n, Double(b) / n))
            out.append(Float(min(1, max(0, c.x)))); out.append(Float(min(1, max(0, c.y)))); out.append(Float(min(1, max(0, c.z))))
        } } }
        return CubeLUT(size: size, rgb: out)
    }

    /// CIColorCube data (RGBA Float32) for this table mixed with the identity: 0 = unchanged, 1 = the table in full.
    public func cubeData(amount: Double) -> Data {
        let a = Float(min(1, max(0, amount)))
        let n = Float(size - 1)
        var out = [Float](repeating: 1, count: size * size * size * 4)
        var i = 0, j = 0
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let id = SIMD3<Float>(Float(r) / n, Float(g) / n, Float(b) / n)
            out[j] = id.x + (rgb[i] - id.x) * a
            out[j + 1] = id.y + (rgb[i + 1] - id.y) * a
            out[j + 2] = id.z + (rgb[i + 2] - id.z) * a
            i += 3; j += 4
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
