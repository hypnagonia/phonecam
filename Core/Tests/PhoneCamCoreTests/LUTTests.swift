import XCTest
@testable import PhoneCamCore

final class LUTTests: XCTestCase {
    func testRedChangesFastest() {
        let lut = CubeLUT.identity(size: 2)
        XCTAssertEqual(Array(lut.rgb[3..<6]), [1, 0, 0]) // second entry: r = 1
    }

    func testAmountMixesWithIdentity() {
        let inverted = CubeLUT.make(size: 2) { SIMD3(1 - $0.x, 1 - $0.y, 1 - $0.z) }
        func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        XCTAssertEqual(floats(inverted.cubeData(amount: 0)), floats(CubeLUT.identity(size: 2).cubeData(amount: 1)))
        let half = floats(inverted.cubeData(amount: 0.5))
        XCTAssertEqual(half.count, 8 * 4)
        XCTAssertTrue(half.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 1 : abs($0.element - 0.5) < 1e-6 })
    }
}
