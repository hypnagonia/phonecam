import XCTest
@testable import PhoneCamCore

final class LUTTests: XCTestCase {
    private func cubeText(size n: Int, title: Bool = true, f: (Double, Double, Double) -> (Double, Double, Double) = { ($0, $1, $2) }) -> String {
        var s = title ? "# made by a test\nTITLE \"Test\"\n" : ""
        s += "LUT_3D_SIZE \(n)\n\n"
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let d = Double(n - 1), o = f(Double(r) / d, Double(g) / d, Double(b) / d)
            s += "\(o.0) \(o.1) \(o.2)\n"
        } } }
        return s
    }

    func testParsesIdentity() throws {
        let lut = try CubeLUT.parse(cubeText(size: 3))
        XCTAssertEqual(lut, CubeLUT.identity(size: 3))
    }

    func testRedChangesFastest() throws {
        let lut = try CubeLUT.parse(cubeText(size: 2))
        XCTAssertEqual(Array(lut.rgb[3..<6]), [1, 0, 0]) // second entry: r = 1, g = b = 0
    }

    func testDomainIsScaled() throws {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" + (0..<8).map { _ in "1 1 1" }.joined(separator: "\r\n")
        XCTAssertEqual(try CubeLUT.parse(text).rgb.first, 0.5)
    }

    func testErrors() {
        XCTAssertThrowsError(try CubeLUT.parse("hello")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .notCube) }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .oneDimensional) }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .wrongCount(expected: 8, got: 1))
        }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 200")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .badSize(200)) }
    }

    func testAmountMixesWithIdentity() throws {
        let inverted = try CubeLUT.parse(cubeText(size: 2) { (1 - $0, 1 - $1, 1 - $2) })
        func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        XCTAssertEqual(floats(inverted.cubeData(amount: 0)), floats(CubeLUT.identity(size: 2).cubeData(amount: 1)))
        let half = floats(inverted.cubeData(amount: 0.5))
        XCTAssertEqual(half.count, 8 * 4)
        XCTAssertTrue(half.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 1 : abs($0.element - 0.5) < 1e-6 })
    }

    func testResamplingKeepsTheColours() {
        // 65 points a side (as many .cube files are) down to the 64 Core Image takes
        let f: (SIMD3<Double>) -> SIMD3<Double> = { SIMD3($0.x * 0.8 + 0.1, $0.y * $0.y, 1 - $0.z) }
        let small = CubeLUT.make(size: 9, f).resampled(to: 5)
        XCTAssertEqual(small.size, 5)
        let want = CubeLUT.make(size: 5, f)
        for (a, b) in zip(small.rgb, want.rgb) { XCTAssertEqual(a, b, accuracy: 0.02) }
        XCTAssertEqual(CubeLUT.identity(size: 7).resampled(to: 4).rgb, CubeLUT.identity(size: 4).rgb)
    }
}

