import XCTest
@testable import PhoneCamCore

final class AppleLogTests: XCTestCase {
    private func code(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> {
        SIMD3(AppleLog.encode(r), AppleLog.encode(g), AppleLog.encode(b))
    }

    func testMidGreyCode() {
        XCTAssertEqual(AppleLog.encode(0.18), 0.488, accuracy: 0.002)
    }

    func testDecodeUndoesEncode() {
        for r in [0.0, 0.005, 0.01, 0.05, 0.18, 1, 4, 11] { XCTAssertEqual(AppleLog.decode(AppleLog.encode(r)), r, accuracy: 1e-6) }
        // the two pieces of the curve meet
        XCTAssertEqual(AppleLog.decode(AppleLog.pt - 1e-9), AppleLog.decode(AppleLog.pt + 1e-9), accuracy: 1e-6)
    }

    func testGreysKeepOrderAndStayGrey() {
        var last = -1.0
        for i in 0...100 {
            let c = AppleLog.develop(SIMD3(repeating: Double(i) / 100))
            XCTAssertEqual(c.x, c.y, accuracy: 1e-3); XCTAssertEqual(c.y, c.z, accuracy: 1e-3)
            XCTAssertGreaterThanOrEqual(c.y, last - 1e-12); last = c.y
        }
        XCTAssertGreaterThan(last, 0.999) // the brightest code is white
    }

    func testFaceLevelIsKept() {
        // what sits at the pivot after the exposure is not moved by the contrast
        let v = AppleLog.pivot / AppleLog.cameraExposure
        XCTAssertEqual(AppleLog.develop(code(v, v, v)).y, AppleLog.pivot, accuracy: 0.004)
    }

    func testContrastMakesColoursFuller() {
        // a muted skin-like colour: the ratio of red to blue grows, the brightness order stays
        let c = AppleLog.develop(code(0.12, 0.09, 0.07))
        let plain = AppleLog.toRec709(SIMD3(0.12, 0.09, 0.07))
        XCTAssertGreaterThan(c.x / c.z, (plain.x / plain.z) * 1.02)
        XCTAssertGreaterThan(c.x, c.y); XCTAssertGreaterThan(c.y, c.z)
    }

    func testColoursOutsideRec709ComeInside() {
        // pure Rec.2020 green: the matrix alone gives negative red and blue
        let raw = AppleLog.toRec709(SIMD3(0, 0.2, 0))
        XCTAssertLessThan(raw.x, 0)
        let c = AppleLog.intoGamut(raw)
        XCTAssertGreaterThanOrEqual(c.x, 0); XCTAssertGreaterThanOrEqual(c.z, 0)
        XCTAssertEqual(c.y, raw.y, accuracy: 1e-9)
        // a colour well inside is not touched
        let inside = SIMD3(0.3, 0.2, 0.15)
        XCTAssertEqual(AppleLog.intoGamut(inside), inside)
    }

    func testBrightColoursFadeToWhiteWithoutClipping() {
        var last = 0.0
        for e in stride(from: 0.05, through: 6, by: 0.05) {
            let c = AppleLog.develop(code(e, e * 0.5, e * 0.3)) // an orange light, brighter and brighter
            XCTAssertLessThanOrEqual(max(c.x, c.y, c.z), 1)
            XCTAssertGreaterThanOrEqual(AppleLog.luma(c), last - 1e-9); last = AppleLog.luma(c)
        }
        XCTAssertGreaterThan(AppleLog.develop(code(6, 3, 1.8)).z, 0.85) // mostly white
    }

    func testExposureFollowsTheFaceCalmly() {
        let t = AppleLog.faceTarget
        XCTAssertEqual(AppleLog.exposureStep(faceLuma: t), 0)
        XCTAssertEqual(AppleLog.exposureStep(faceLuma: t * 1.08), 0) // inside the dead zone
        XCTAssertGreaterThan(AppleLog.exposureStep(faceLuma: t / 2), 0)
        XCTAssertLessThan(AppleLog.exposureStep(faceLuma: t * 2), 0)
        XCTAssertEqual(AppleLog.exposureStep(faceLuma: 0.001), 0.06, accuracy: 1e-9) // never more than one step
        // one stop as a code offset is one stop of light on the log part of the curve
        let v = 0.2, code = AppleLog.encode(v) + AppleLog.codeOffset(stops: 1)
        XCTAssertEqual(AppleLog.decode(code) + AppleLog.beta, 2 * (v + AppleLog.beta), accuracy: 1e-6)
    }

    func testShoulderHoldsEverythingTheFrameHolds() {
        // straight below the knee, no kink at it, white only at the brightest light
        XCTAssertEqual(AppleLog.shoulder(0.3), 0.3)
        let d = 1e-6, slope = (AppleLog.shoulder(AppleLog.knee + d) - AppleLog.shoulder(AppleLog.knee)) / d
        XCTAssertEqual(slope, 1, accuracy: 0.01)
        XCTAssertEqual(AppleLog.shoulder(AppleLog.brightest), 1, accuracy: 1e-9)
        // a bright window (4 and 8 times the screen's white) still has steps between its tones
        XCTAssertLessThan(AppleLog.shoulder(4), 0.85)
        XCTAssertGreaterThan(AppleLog.shoulder(8) - AppleLog.shoulder(4), 0.04)
        var last = 0.0
        for i in 1...300 { let y = AppleLog.shoulder(Double(i) / 10); XCTAssertGreaterThanOrEqual(y, last); last = y }
    }
}
