import XCTest
import CoreGraphics
@testable import PhoneCamCore

final class AccentsTests: XCTestCase {
    /// A 100×50 grey-white room with a few coloured pixels.
    func room(_ paint: (Int, Int) -> (UInt8, UInt8, UInt8)?) -> [UInt8] {
        var px = [UInt8](); px.reserveCapacity(100 * 50 * 4)
        for y in 0..<50 { for x in 0..<100 {
            let c = paint(x, y) ?? (200, 198, 195)
            px += [c.0, c.1, c.2, 255]
        } }
        return px
    }
    let all = CGRect(x: 0, y: 0, width: 1, height: 1)

    func testSmallBlueLampIsBoosted() {
        // 2 % of the picture: a blue lamp.
        let px = room { x, y in x >= 90 && y >= 40 ? (60, 110, 230) : nil }
        let s = Accents.analyze(rgba: px, width: 100, height: 50, window: all, face: nil)
        XCTAssertEqual(s.coverage[5] + s.coverage[4], 0.02, accuracy: 0.002)
        let t = Accents.target(s, strength: 1, faceInView: false)
        XCTAssertGreaterThan(t[5], 0.1)
        XCTAssertEqual(t[3], 0) // no green: nothing
    }

    func testHugeAcidWallIsCalmed() {
        let px = room { x, _ in x < 50 ? (20, 210, 40) : nil } // half the picture acid green
        let t = Accents.target(Accents.analyze(rgba: px, width: 100, height: 50, window: all, face: nil), strength: 1, faceInView: false)
        XCTAssertLessThan(t[3], 0)
    }

    func testColouredLightOnAWallIsBoosted() {
        // A blue light washing a fifth of the room, moderately coloured (like a lamp on a white wall).
        let px = room { x, _ in x < 22 ? (110, 125, 160) : nil }
        let s = Accents.analyze(rgba: px, width: 100, height: 50, window: all, face: nil)
        let t = Accents.target(s, strength: 1, faceInView: true)
        XCTAssertGreaterThan(t[5] + t[4], 0.2)
        XCTAssertLessThan(t[5], 0.45)
    }

    func testSkinIsNeverBoostedAndFaceIsLeftOut() {
        let face = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3)
        // Orange-ish skin only inside the face box: excluded from the analysis.
        let px = room { x, y in face.contains(CGPoint(x: (Double(x) + 0.5) / 100, y: (Double(y) + 0.5) / 50)) ? (220, 150, 120) : nil }
        let s = Accents.analyze(rgba: px, width: 100, height: 50, window: all, face: face)
        XCTAssertEqual(s.coverage[1], 0, accuracy: 1e-9)
        // A small orange object elsewhere while a face is in view: still not boosted (it is skin's colour).
        var s2 = Accents.Stats(); s2.coverage[1] = 0.02; s2.chroma[1] = 0.3
        XCTAssertEqual(Accents.target(s2, strength: 1, faceInView: true)[1], 0)
        XCTAssertEqual(Accents.target(s2, strength: 1, faceInView: false)[1], 0, "not even with nobody in view")
    }

    func testTrackerIgnoresShortEventsAndMovesSlowly() {
        var tr = Accents.Tracker()
        var steady = [Double](repeating: 0, count: 8); steady[5] = 0.3
        var flash = steady; flash[0] = 0.4 // something red for one look
        var v = tr.update(steady)
        XCTAssertLessThan(v[5], 0.05, "slow start")
        v = tr.update(flash)
        for _ in 0..<40 { v = tr.update(steady) }
        XCTAssertEqual(v[5], 0.3, accuracy: 0.02, "settles on the steady look")
        XCTAssertEqual(v[0], 0, accuracy: 0.002, "the one-off red changed nothing")
    }

    func testWindowLimitsAnalysis() {
        // A blue lamp outside the streamed crop doesn't count.
        let px = room { x, y in x >= 90 && y >= 40 ? (60, 110, 230) : nil }
        let s = Accents.analyze(rgba: px, width: 100, height: 50, window: CGRect(x: 0, y: 0, width: 0.8, height: 1), face: nil)
        XCTAssertEqual(s.coverage[5] + s.coverage[4], 0)
    }
}
