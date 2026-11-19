import XCTest
import CoreGraphics
@testable import PhoneCamCore

final class AutoOperatorTests: XCTestCase {
    func testHoldWaitsForCalmAndReleasesOnRealChange() {
        var h = AutoOperator.Hold(settle: 0.15, change: 0.6)
        XCTAssertNil(h.step(0.05))
        XCTAssertEqual(h.step(0.05), .hold)          // 2 calm seconds
        XCTAssertNil(h.step(0.9))                    // a hand in front: one second
        XCTAssertNil(h.step(0.1))                    // gone: still held
        XCTAssertTrue(h.held)
        XCTAssertNil(h.step(0.9))
        XCTAssertEqual(h.step(0.8), .release)        // the light really changed
        XCTAssertFalse(h.held)
    }

    func testLightBrightensFaceDarkensEdges() {
        let size = CGSize(width: 1920, height: 1080)
        let l = AutoOperator.light(size: size, faceCenter: CGPoint(x: 0.5, y: 0.4), faceSize: 0.3, faceLuma: 0.3, strength: 1)
        XCTAssertGreaterThan(l.face, 1.05); XCTAssertLessThan(l.edge, 0.9)
        XCTAssertEqual(l.center.y, 432, accuracy: 0.5)
        let bright = AutoOperator.light(size: size, faceCenter: CGPoint(x: 0.5, y: 0.4), faceSize: 0.3, faceLuma: 0.7, strength: 1)
        XCTAssertLessThan(bright.face, l.face, "a bright face gets less light")
        let none = AutoOperator.light(size: size, faceCenter: nil, faceSize: 0.3, faceLuma: nil, strength: 1)
        XCTAssertEqual(none.face, 1)
        let off = AutoOperator.light(size: size, faceCenter: CGPoint(x: 0.5, y: 0.4), faceSize: 0.3, faceLuma: 0.3, strength: 0)
        XCTAssertEqual(off.face, 1); XCTAssertEqual(off.edge, 1)
    }

    func histogram(_ f: (Int) -> Double) -> [Double] { (0..<64).map(f) }

    func testToneFlatAndDark() {
        // Flat: everything between 0.35 and 0.6.
        let flat = AutoOperator.tone(histogram: histogram { $0 >= 22 && $0 < 38 ? 1 : 0 }, strength: 1)
        XCTAssertGreaterThan(flat.contrast, 0.05)
        // Dark: most of it in the lower quarter.
        let dark = AutoOperator.tone(histogram: histogram { $0 < 16 ? 4 : ($0 < 60 ? 0.2 : 0) }, strength: 1)
        XCTAssertGreaterThan(dark.mids, 0.05)
        // Well spread and bright enough: almost nothing.
        let good = AutoOperator.tone(histogram: histogram { _ in 1 }, strength: 1)
        XCTAssertTrue(good.isNeutral || (good.contrast < 0.02 && abs(good.mids) < 0.03))
    }

    func testTonePointsKeepEndsAndOrder() {
        var t = AutoOperator.Tone(); t.contrast = 0.15; t.mids = 0.15
        let p = t.points
        XCTAssertEqual(p.first!.1, 0, accuracy: 1e-9); XCTAssertEqual(p.last!.1, 1, accuracy: 1e-9)
        XCTAssertTrue(zip(p, p.dropFirst()).allSatisfy { $0.1 < $1.1 }, "still rising")
    }

    func testToneTrackerIsSlow() {
        var tr = AutoOperator.ToneTracker()
        var t = AutoOperator.Tone(); t.contrast = 0.1
        let first = tr.update(t)
        XCTAssertLessThan(first.contrast, 0.02)
        var v = first
        for _ in 0..<40 { v = tr.update(t) }
        XCTAssertEqual(v.contrast, 0.1, accuracy: 0.01)
    }
}
