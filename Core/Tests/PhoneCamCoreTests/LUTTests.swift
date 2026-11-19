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

    func testLooks() {
        for name in Looks.names {
            guard let lut = Looks.lut(name, size: 17) else { return XCTFail(name) }
            // Brightness keeps its order along the grey axis (no inverted tones), blacks and whites stay sensible.
            var last = -1.0
            for i in 0..<17 {
                let k = (i * 17 * 17 + i * 17 + i) * 3
                let y = 0.2126 * Double(lut.rgb[k]) + 0.7152 * Double(lut.rgb[k + 1]) + 0.0722 * Double(lut.rgb[k + 2])
                XCTAssertGreaterThan(y, last, "\(name) grey \(i)")
                last = y
            }
            XCTAssertLessThan(lut.rgb[0], 0.1, name)
            XCTAssertGreaterThan(lut.rgb[lut.rgb.count - 2], 0.9, name)
        }
        XCTAssertNil(Looks.lut("Nope"))
        // Mono has no colour.
        let mono = Looks.lut("Mono", size: 9)!
        let k = (8 * 9 * 9 + 0 * 9 + 0) * 3 // pure blue in
        XCTAssertLessThan(abs(mono.rgb[k] - mono.rgb[k + 1]), 0.02)
    }
}

