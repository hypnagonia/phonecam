import XCTest
import simd
@testable import PhoneCamCore

final class HSLTests: XCTestCase {
    let green = SIMD3(0.25, 0.6, 0.2), blue = SIMD3(0.2, 0.35, 0.75), red = SIMD3(0.75, 0.2, 0.18)
    let grey = SIMD3(0.5, 0.5, 0.5)
    func cube(_ c: SIMD3<Double>, _ h: HSL) -> SIMD3<Double> { ColorCube.apply(c, hsl: h, skinCenter: 20, skinShift: 0) }

    func testStringRoundTrip() {
        var h = HSL(); h.hue[3] = 0.5; h.sat[5] = -0.25; h.lum[1] = 1
        XCTAssertEqual(HSL(string: h.string), h)
        XCTAssertTrue(HSL(string: "").isNeutral)
        XCTAssertTrue(HSL(string: "garbage").isNeutral)
        XCTAssertEqual(HSL(string: "9,9,9").sat[0], 1) // clamped
    }

    func testNeutralChangesNothing() {
        for c in [green, blue, red, grey] { XCTAssertLessThan(simd_distance(cube(c, HSL()), c), 1e-9) }
        XCTAssertNil(ColorCube.make(hsl: HSL(), skinCenter: 20, skinShift: 0))
    }

    func testBlueSaturationLeavesRedAlone() {
        var h = HSL(); h.sat[5] = -1
        let b = cube(blue, h)
        XCTAssertLessThan(max(b.x, b.y, b.z) - min(b.x, b.y, b.z), 0.08, "blue goes grey")
        XCTAssertLessThan(simd_distance(cube(red, h), red), 1e-9, "red untouched")
        XCTAssertLessThan(simd_distance(cube(grey, h), grey), 1e-9, "grey untouched")
    }

    func testGreenHueShiftsTowardYellow() {
        var h = HSL(); h.hue[3] = -1
        let g = cube(green, h)
        XCTAssertGreaterThan(g.x, green.x + 0.05, "more red in it: toward yellow")
    }

    func testLuminance() {
        var h = HSL(); h.lum[5] = -1
        let b = cube(blue, h)
        XCTAssertLessThan(b.z, blue.z - 0.1)
    }

    func testSmoothBetweenColours() {
        // Halfway between orange (30°) and yellow (60°) gets half of an orange-only change.
        var h = HSL(); h.sat[1] = 1
        XCTAssertEqual(h.adjustment(hue: 30).ds, 1, accuracy: 1e-9)
        XCTAssertEqual(h.adjustment(hue: 45).ds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(h.adjustment(hue: 60).ds, 0, accuracy: 1e-9)
        XCTAssertEqual(h.adjustment(hue: 350).ds, 0, accuracy: 1e-9) // between magenta and red
    }

    func testOldSlidersMigrate() {
        let h = HSL.fromOldSliders(red: 1, green: 1, blue: 1.34)
        XCTAssertEqual(h.sat[5], 0.34, accuracy: 1e-9)
        XCTAssertEqual(h.sat[4], 0.34, accuracy: 1e-9)
        XCTAssertEqual(h.sat[0], 0)
    }
}

final class VibranceTests: XCTestCase {
    private func sat(_ c: SIMD3<Double>) -> Double { (max(c.x, c.y, c.z) - min(c.x, c.y, c.z)) / max(c.x, c.y, c.z) }
    private func vib(_ c: SIMD3<Double>, _ v: Double) -> SIMD3<Double> {
        ColorCube.apply(c, hsl: HSL(), skinCenter: 20, skinShift: 0, vibrance: v)
    }

    func testWeakColoursGainMostFullOnesAlmostNothing() {
        let weak = SIMD3(0.40, 0.50, 0.62), full = SIMD3(0.05, 0.30, 0.95)
        XCTAssertGreaterThan(sat(vib(weak, 1)) / sat(weak), 1.15)
        XCTAssertLessThan(sat(vib(full, 1)) / sat(full), 1.02)
        XCTAssertEqual(vib(weak, 0), weak)
    }

    func testSkinGetsItLikeAnyColourAndGreyNone() {
        let skin = SIMD3(0.78, 0.60, 0.50), blue = SIMD3(0.50, 0.60, 0.78) // equally weak colours
        XCTAssertEqual(sat(vib(skin, 1)) / sat(skin), sat(vib(blue, 1)) / sat(blue), accuracy: 0.03)
        let grey = SIMD3(repeating: 0.5)
        XCTAssertEqual(vib(grey, 1), grey)
    }
}
