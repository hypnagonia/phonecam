import XCTest
@testable import PhoneCamCore

final class OrientationTests: XCTestCase {
    let deg = Double.pi / 180

    /// Gravity angle for a phone mounted so the picture needs `rotation`, rolled by `roll` degrees.
    func phi(_ rotation: Int, roll: Double = 0) -> Double {
        var d = Double(rotation) - 180 + roll
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d * deg
    }

    func testRotationForEachMount() {
        for r in [0, 90, 180, 270] {
            XCTAssertEqual(OrientationTracker.rotation(phi: phi(r)), r)
            XCTAssertEqual(OrientationTracker.rotation(phi: phi(r, roll: 20)), r)
            XCTAssertEqual(OrientationTracker.rotation(phi: phi(r, roll: -20)), r)
        }
    }

    func testSwitchesOnlyAfterStableSamples() {
        var t = OrientationTracker(needed: 10)
        for _ in 0..<10 { XCTAssertNil(t.update(phi: phi(90))) }
        XCTAssertEqual(t.update(phi: phi(90)), 90)
        XCTAssertEqual(t.update(phi: phi(90, roll: 3)), 90)
    }

    /// The bug: one bumped sample used to switch the picture to its own guess.
    func testOneBumpNeverSwitches() {
        var t = OrientationTracker(needed: 10)
        for _ in 0..<20 { _ = t.update(phi: phi(180)) }
        XCTAssertEqual(t.update(phi: phi(180)), 180)
        // A bump far into the next quarter (clear sample) and one between positions (unclear sample).
        XCTAssertNil(t.update(phi: phi(90)))
        XCTAssertNil(t.update(phi: phi(180, roll: 40)))
        // Back to normal: nothing is returned until the count is rebuilt, and then the old position.
        for _ in 0..<10 { XCTAssertNil(t.update(phi: phi(180))) }
        XCTAssertEqual(t.update(phi: phi(180)), 180)
    }

    func testUnclearSamplesNeverSettle() {
        var t = OrientationTracker(needed: 3)
        for _ in 0..<20 { XCTAssertNil(t.update(phi: phi(0, roll: 44))) }
        XCTAssertEqual(t.candidate, -1)
    }

    func testWrapAroundMinus180() {
        // gravity along -x reads phi = ±180°; both sides mean rotation 0
        XCTAssertEqual(OrientationTracker.rotation(phi: .pi - 0.01), 0)
        XCTAssertEqual(OrientationTracker.rotation(phi: -.pi + 0.01), 0)
        var t = OrientationTracker(needed: 4)
        var got: Int?
        for i in 0..<10 { got = t.update(phi: i % 2 == 0 ? .pi - 0.01 : -.pi + 0.01) }
        XCTAssertEqual(got, 0)
    }
}

final class LevelTests: XCTestCase {
    let deg = Double.pi / 180

    func testRollIsClamped() {
        XCTAssertEqual(Level.roll(phi: 3 * deg), 3 * deg, accuracy: 1e-12)
        XCTAssertEqual(Level.roll(phi: (90 + 3) * deg), 3 * deg, accuracy: 1e-12)
        XCTAssertEqual(Level.roll(phi: 30 * deg), Level.maxTilt, accuracy: 1e-12)
        XCTAssertEqual(Level.roll(phi: -30 * deg), -Level.maxTilt, accuracy: 1e-12)
    }

    func testNoCorrectionInsideDeadZone() {
        XCTAssertEqual(Level.correction(tilt: 0), 0)
        XCTAssertEqual(Level.correction(tilt: 0.49 * deg), 0)
        XCTAssertEqual(Level.correction(tilt: -0.49 * deg), 0)
    }

    /// The bug: crossing 0.5° switched a 0.5° turn and a 1.6 % zoom on at once.
    func testCorrectionIsContinuousAtDeadZone() {
        let just = Level.correction(tilt: Level.deadZone + 1e-6)
        XCTAssertEqual(just, 0, accuracy: 1e-5)
        XCTAssertEqual(Level.zoom(width: 1920, height: 1080, angle: just), 1, accuracy: 1e-4)
        XCTAssertEqual(Level.correction(tilt: 2 * deg), -1.5 * deg, accuracy: 1e-12)
        XCTAssertEqual(Level.correction(tilt: -2 * deg), 1.5 * deg, accuracy: 1e-12)
    }

    func testCorrectionChangesSmoothly() {
        // a 0.01° step in tilt never moves the picture more than 0.01°
        var prev = Level.correction(tilt: -3 * deg)
        for i in -299...300 {
            let c = Level.correction(tilt: Double(i) / 100 * deg)
            XCTAssertLessThanOrEqual(abs(c - prev), 0.0100001 * deg)
            prev = c
        }
    }

    func testZoomHidesCorners() {
        XCTAssertEqual(Level.zoom(width: 1920, height: 1080, angle: 0), 1)
        let a = 5 * deg
        let z = Level.zoom(width: 1920, height: 1080, angle: a)
        // the turned, zoomed frame must cover the original corners
        let hw = 1920.0 / 2, hh = 1080.0 / 2
        for (x, y) in [(hw, hh), (-hw, hh), (hw, -hh), (-hw, -hh)] {
            // corner in the frame of the turned picture
            let u = (x * cos(a) + y * sin(a)) / z, v = (-x * sin(a) + y * cos(a)) / z
            XCTAssertLessThanOrEqual(abs(u), hw + 1e-9)
            XCTAssertLessThanOrEqual(abs(v), hh + 1e-9)
        }
    }
}
