import CoreGraphics
import XCTest
@testable import PhoneCamCore

final class PortraitTests: XCTestCase {
    let w = 96, h = 54
    let face = CGRect(x: 0.42, y: 0.1, width: 0.16, height: 0.28)
    let window = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// A frame: grey room, a large olive-green wall on the left, a small cyan lamp on the right, skin at the
    /// face, and a blue shirt (hue 200°, off the clean 212°) below the face.
    func frame(shirt: SIMD3<Double> = SIMD3(0.25, 0.55, 0.85), lamp: Bool = true) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let x = (Double(col) + 0.5) / Double(w), y = (Double(row) + 0.5) / Double(h)
                var c = SIMD3(0.5, 0.5, 0.48)                                           // room
                if x < 0.3 { c = SIMD3(0.55, 0.6, 0.35) }                               // olive wall
                if lamp, x > 0.88, x < 0.92, y > 0.2, y < 0.27 { c = SIMD3(0.2, 0.85, 0.85) } // lamp
                if face.contains(CGPoint(x: x, y: y)) { c = SIMD3(0.85, 0.6, 0.48) }    // skin
                if x > face.midX - face.width * 1.2, x < face.midX + face.width * 1.2, y > face.maxY + face.height * 0.5 {
                    c = shirt
                }
                let i = (row * w + col) * 4
                px[i] = UInt8(c.x * 255); px[i + 1] = UInt8(c.y * 255); px[i + 2] = UInt8(c.z * 255); px[i + 3] = 255
            }
        }
        return px
    }

    func testClothesRicherAndCleaner() {
        let s = Portrait.analyze(rgba: frame(), width: w, height: h, window: window, face: face)
        XCTAssertTrue(s.hasPerson)
        let t = Portrait.target(s, strength: 1)
        // the shirt sits between aqua (4) and blue (5): both richer, both turned toward 212° (positive)
        for i in [4, 5] where s.clothes[i] >= 0.08 {
            XCTAssertGreaterThan(t.sat[i], 0.05, "band \(i)")
            XCTAssertGreaterThan(t.hue[i], 0, "band \(i)")
            XCTAssertLessThanOrEqual(t.hue[i] * 30, Portrait.maxTurn + 1e-9)
        }
        XCTAssertGreaterThan(s.clothes[4] + s.clothes[5], 0.5)
    }

    func testAccentAndCalmBackground() {
        let s = Portrait.analyze(rgba: frame(), width: w, height: h, window: window, face: face)
        let t = Portrait.target(s, strength: 1)
        // the olive wall (yellow/green, a big share of the background) is calmer, never the accent
        XCTAssertLessThan(t.sat[2] + t.sat[3], 0)
        // the cyan lamp shares the shirt's aqua band, so there is no accent at all: nothing outside the shirt gains
        for i in 0..<8 where s.clothes[i] < 0.08 { XCTAssertLessThanOrEqual(t.sat[i], 1e-9, "band \(i)") }
        // the cyan lamp is small and not a shirt colour... but cyan *is* the shirt's aqua band here, so the
        // accent goes elsewhere or nowhere; with a red lamp it must be the red band
        var px = frame(shirt: SIMD3(0.25, 0.55, 0.85), lamp: false)
        for row in 0..<h {
            for col in 0..<w {
                let x = (Double(col) + 0.5) / Double(w), y = (Double(row) + 0.5) / Double(h)
                if x > 0.88, x < 0.92, y > 0.2, y < 0.27 {
                    let i = (row * w + col) * 4
                    px[i] = 230; px[i + 1] = 30; px[i + 2] = 60
                }
            }
        }
        let s2 = Portrait.analyze(rgba: px, width: w, height: h, window: window, face: face)
        let t2 = Portrait.target(s2, strength: 1)
        let accent = (0..<8).max { t2.sat[$0] < t2.sat[$1] }!
        XCTAssertTrue(accent == 0 || accent == 7 || accent == 4 || accent == 5, "accent \(accent)")
        XCTAssertGreaterThan(t2.sat[0] + t2.sat[7], 0.1, "the red lamp is the accent")
    }

    /// The phone mounted upside down (rotation 180): the sensor frame is the picture turned round, the face box
    /// comes in sensor coordinates; the clothes must still be found below the face in the picture.
    func testUpsideDownMountFindsTheSameClothes() {
        let up = Portrait.analyze(rgba: frame(), width: w, height: h, window: window, face: face)
        var turned = [UInt8](repeating: 0, count: w * h * 4)
        let src = frame()
        for row in 0..<h { for col in 0..<w {
            let a = (row * w + col) * 4, b = ((h - 1 - row) * w + (w - 1 - col)) * 4
            for k in 0..<4 { turned[b + k] = src[a + k] }
        } }
        let sensorFace = CGRect(x: 1 - face.maxX, y: 1 - face.maxY, width: face.width, height: face.height)
        let down = Portrait.analyze(rgba: turned, width: w, height: h, window: window, face: sensorFace, rotation: 180)
        for i in 0..<8 {
            XCTAssertEqual(down.clothes[i], up.clothes[i], accuracy: 0.02, "band \(i)")
            XCTAssertEqual(down.background[i], up.background[i], accuracy: 0.02, "band \(i)")
        }
    }

    func testSkinIsNotAClothesColour() {
        // a "shirt" in the face's own tone (hands, a bare neck): not counted as clothes
        let skin = ColorCube.withHue(SIMD3(0.8, 0.58, 0.45), 18)
        let s = Portrait.analyze(rgba: frame(shirt: skin), width: w, height: h, window: window, face: face, skinHue: 18)
        XCTAssertLessThan(s.clothes.reduce(0, +), 0.05)
    }

    /// The real case: an olive sweater the camera sees at ~34° under a face at ~13°: it is clothes, gets richer,
    /// and goes back toward olive.
    func testOliveSweaterIsClothes() {
        let sweater = ColorCube.withHue(SIMD3(0.42, 0.34, 0.24), 34)
        let s = Portrait.analyze(rgba: frame(shirt: sweater), width: w, height: h, window: window, face: face, skinHue: 13)
        XCTAssertGreaterThan(s.clothes[1] + s.clothes[2], 0.5)
        let t = Portrait.target(s, strength: 1)
        XCTAssertGreaterThan(t.sat[1], 0.05)
        XCTAssertGreaterThan(t.hue[1], 0, "toward olive / golden 48°")
    }

    func testNoPersonOnlyAccentAndCalm() {
        let s = Portrait.analyze(rgba: frame(), width: w, height: h, window: window, face: nil)
        XCTAssertFalse(s.hasPerson)
        let t = Portrait.target(s, strength: 1)
        XCTAssertTrue(t.hue.allSatisfy { $0 == 0 })
    }

    func testStrengthZeroChangesNothing() {
        let s = Portrait.analyze(rgba: frame(), width: w, height: h, window: window, face: face)
        let t = Portrait.target(s, strength: 0)
        XCTAssertTrue(t.hue.allSatisfy { $0 == 0 } && t.sat.allSatisfy { abs($0) < 1e-12 })
    }

    func testTurnToClean() {
        XCTAssertEqual(Portrait.turnToClean(212), 0, accuracy: 1e-9)
        XCTAssertEqual(Portrait.turnToClean(205), 7, accuracy: 1e-9)
        XCTAssertEqual(Portrait.turnToClean(190), -12, accuracy: 1e-9)   // nearer to 178: down, capped
        XCTAssertEqual(Portrait.turnToClean(350), 5, accuracy: 1e-9)     // across 0°/360°
        XCTAssertEqual(Portrait.turnToClean(34), 12, accuracy: 1e-9)     // olive seen warm → back toward olive, capped
    }
}

final class SkinTanTests: XCTestCase {
    func hueOf(_ c: SIMD3<Double>) -> Double { ColorCube.hue(c)! }

    func testReddishSkinWarmsUp() {
        let red = ColorCube.withHue(SIMD3(0.8, 0.5, 0.45), 12)
        let out = ColorCube.tan(red, amount: 1)
        XCTAssertGreaterThan(hueOf(out), 15)
        XCTAssertLessThanOrEqual(hueOf(out), ColorCube.tanHue + 0.5)
    }

    func testGreenishSkinComesBack() {
        let green = ColorCube.withHue(SIMD3(0.8, 0.6, 0.45), 42)
        let out = ColorCube.tan(green, amount: 1)
        XCTAssertLessThan(hueOf(out), 35)
        XCTAssertGreaterThanOrEqual(hueOf(out), ColorCube.tanHue - 0.5)
    }

    func testTanIsRicherAndDeeper() {
        let skin = ColorCube.withHue(SIMD3(0.82, 0.6, 0.5), 23)
        let out = ColorCube.tan(skin, amount: 1)
        let chroma = { (c: SIMD3<Double>) in max(c.x, c.y, c.z) - min(c.x, c.y, c.z) }
        XCTAssertGreaterThan(chroma(out), chroma(skin))
        XCTAssertLessThan(out.x + out.y + out.z, skin.x + skin.y + skin.z)
    }

    func testCubeKeepsSkinOutOfTheBands() {
        // a strong red-band boost must not reach skin when the tan is on
        var hsl = HSL()
        hsl.sat[0] = 1; hsl.sat[1] = 1
        let skin = ColorCube.withHue(SIMD3(0.82, 0.6, 0.5), 22)
        let withTan = ColorCube.apply(skin, hsl: hsl, saturation: 1, skinCenter: 22, skinShift: 0, skinTan: 1)
        let plainTan = ColorCube.tan(skin, amount: 1)
        XCTAssertEqual(withTan.x, plainTan.x, accuracy: 0.02)
        XCTAssertEqual(withTan.y, plainTan.y, accuracy: 0.02)
        XCTAssertEqual(withTan.z, plainTan.z, accuracy: 0.02)
        // and greys stay grey
        let grey = SIMD3(0.5, 0.5, 0.5)
        XCTAssertEqual(ColorCube.apply(grey, hsl: hsl, saturation: 1, skinCenter: 22, skinShift: 0, skinTan: 1), grey)
    }

    func testNoTanIsTheOldCube() {
        var hsl = HSL()
        hsl.sat[5] = 0.4
        let c = SIMD3(0.2, 0.4, 0.8)
        XCTAssertEqual(ColorCube.apply(c, hsl: hsl, saturation: 1, skinCenter: 22, skinShift: 0),
                       ColorCube.apply(c, hsl: hsl, saturation: 1, skinCenter: 22, skinShift: 0, skinTan: 0))
    }
}

final class BlackPointTests: XCTestCase {
    func testMilkyBlacksArePulledDown() {
        // a picture whose darkest pixels sit at ~0.12 (lifted, milky)
        var h = [Double](repeating: 0, count: 64)
        for i in 8..<56 { h[i] = 10 }
        let t = AutoOperator.tone(histogram: h, strength: 1)
        XCTAssertEqual(t.black, (0.133 - 0.04) * 0.7, accuracy: 0.01)   // most of the way to a deep black
        XCTAssertEqual(t.map(0), 0, accuracy: 1e-9)
        XCTAssertEqual(t.map(1), 1, accuracy: 1e-9)
        // and its brightest (~0.87) comes up toward white
        XCTAssertEqual(t.white, (0.96 - 0.867) * 0.6, accuracy: 0.01)
        XCTAssertGreaterThan(t.map(0.867), 0.9)
        XCTAssertGreaterThan(t.map(0.5), 0.4); XCTAssertLessThan(t.map(0.5), 0.6) // the middle stays the middle
    }

    func testTheEndsAreRoundedNotCut() {
        var t = AutoOperator.Tone(); t.black = 0.1; t.white = 0.06
        // at the black point the curve is still above black and climbing; no step in its slope anywhere
        XCTAssertGreaterThan(t.map(0.1), 0.005)
        var last = -1.0, lastStep = 0.0
        for i in 0...200 {
            let y = t.map(Double(i) / 200)
            XCTAssertGreaterThanOrEqual(y, last)
            if i > 1 { XCTAssertLessThan(abs((y - last) - lastStep), 0.004) }
            if i > 0 { lastStep = y - last }
            last = y
        }
    }

    func testThePointsHaveLimits() {
        // a dim, flat picture (everything between 0.3 and 0.6) is not stretched to full black and white
        var h = [Double](repeating: 0, count: 64)
        for i in 20..<38 { h[i] = 10 }
        let t = AutoOperator.tone(histogram: h, strength: 1)
        XCTAssertEqual(t.black, 0.14, accuracy: 1e-9)
        XCTAssertEqual(t.white, 0.08, accuracy: 1e-9)
    }

    func testAPictureWithWhiteKeepsItsWhitePoint() {
        var h = [Double](repeating: 0, count: 64)
        for i in 0..<64 { h[i] = 10 }
        XCTAssertEqual(AutoOperator.tone(histogram: h, strength: 1).white, 0, accuracy: 1e-9)
    }

    func testRealBlacksStay() {
        var h = [Double](repeating: 0, count: 64)
        for i in 0..<56 { h[i] = 10 }
        XCTAssertEqual(AutoOperator.tone(histogram: h, strength: 1).black, 0, accuracy: 1e-9)
    }
}
