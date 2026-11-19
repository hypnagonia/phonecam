import Foundation

/// A 3D colour lookup table: `size`³ RGB entries, red changing fastest, then green, then blue (the order of
/// both the .cube format and Core Image's CIColorCube). Values are for gamma-encoded Rec.709/sRGB video.
public struct CubeLUT: Equatable {
    public let size: Int
    public let rgb: [Float]      // size³ × 3, 0…1

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notCube, oneDimensional, badSize(Int), wrongCount(expected: Int, got: Int), badNumber(line: Int)
        public var description: String {
            switch self {
            case .notCube: return "not a .cube file (no LUT_3D_SIZE)"
            case .oneDimensional: return "1D LUTs are not supported, only 3D"
            case let .badSize(n): return "LUT size \(n) is not supported (2…65)"
            case let .wrongCount(e, g): return "expected \(e) colour lines, found \(g)"
            case let .badNumber(l): return "unreadable numbers on line \(l)"
            }
        }
    }

    public static let maxSize = 65

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

    /// Reads an Adobe/Resolve .cube file (TITLE, LUT_3D_SIZE, DOMAIN_MIN/MAX, comments).
    public static func parse(_ text: String) throws -> CubeLUT {
        var size: Int?
        var lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let key = parts[0].uppercased()
            func three() throws -> SIMD3<Float> {
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 3 else { throw ParseError.badNumber(line: i + 1) }
                return SIMD3(v[0], v[1], v[2])
            }
            switch key {
            case "TITLE": continue
            case "LUT_1D_SIZE": throw ParseError.oneDimensional
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else { throw ParseError.badNumber(line: i + 1) }
                guard (2...maxSize).contains(n) else { throw ParseError.badSize(n) }
                size = n
                values.reserveCapacity(n * n * n * 3)
            case "DOMAIN_MIN": lo = try three()
            case "DOMAIN_MAX": hi = try three()
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE": continue
            default:
                guard let first = key.first, first.isNumber || first == "-" || first == "." || first == "+" else { continue }
                let v = parts.compactMap { Float($0) }
                guard v.count == 3, parts.count == 3 else { throw ParseError.badNumber(line: i + 1) }
                values.append(contentsOf: v)
            }
        }
        guard let n = size else { throw ParseError.notCube }
        guard values.count == n * n * n * 3 else { throw ParseError.wrongCount(expected: n * n * n, got: values.count / 3) }
        // Output values are in the same units as the domain: bring them to 0…1.
        if lo != SIMD3(0, 0, 0) || hi != SIMD3(1, 1, 1) {
            let span = hi - lo
            for j in 0..<values.count { let c = j % 3; values[j] = (values[j] - lo[c]) / max(span[c], 1e-6) }
        }
        return CubeLUT(size: n, rgb: values.map { min(1, max(0, $0)) })
    }

    /// CIColorCube data (RGBA Float32) for this table mixed with the identity: 0 = unchanged, 1 = full look.
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
