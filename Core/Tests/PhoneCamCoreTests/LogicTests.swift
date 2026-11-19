import XCTest
import CoreGraphics
@testable import PhoneCamCore

final class FrameMathTests: XCTestCase {
    func testRotationRoundTrip() {
        for r in [0, 90, 180, 270] {
            for (u, v) in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.3), (0, 1)] {
                let p = FrameMath.toDisplay(FrameMath.toSensor(u: u, v: v, rotation: r), rotation: r)
                XCTAssertEqual(p.x, u, accuracy: 1e-12, "rotation \(r)")
                XCTAssertEqual(p.y, v, accuracy: 1e-12, "rotation \(r)")
            }
        }
    }

    func testWindowIs16by9AndInsideSensor() {
        let a = 2160.0 / 3840 // landscape sensor, 16:9
        for r in [0, 90, 180, 270] {
            for z in [1.0, 1.15, 2, 3] {
                let w = FrameMath.windowSize(rotation: r, zoom: z, sensorAspect: a)
                XCTAssertLessThanOrEqual(w.w, 1); XCTAssertLessThanOrEqual(w.h, 1)
                // Shown aspect (in pixels): landscape picture of 16:9.
                let shown = (r == 90 || r == 270) ? (w.h * 2160) / (w.w * 3840) : (w.w * 3840) / (w.h * 2160)
                XCTAssertEqual(shown, 16.0 / 9, accuracy: 1e-9, "rotation \(r) zoom \(z)")
            }
        }
        let full = FrameMath.windowSize(rotation: 0, zoom: 1, sensorAspect: a)
        XCTAssertEqual(full.w, 1, accuracy: 1e-12); XCTAssertEqual(full.h, 1, accuracy: 1e-12)
    }

    func testBitrateRange() {
        XCTAssertEqual(FrameMath.bitrate(quality: 0), 4_000_000)
        XCTAssertEqual(FrameMath.bitrate(quality: 0.95), 24_000_000)
        XCTAssertEqual(FrameMath.bitrate(quality: 2), 24_000_000)
    }
}

final class PresetsTests: XCTestCase {
    func testNames() {
        XCTAssertNil(Presets.cleanName("   "))
        XCTAssertEqual(Presets.cleanName("  Day  "), "Day")
        XCTAssertEqual(Presets.cleanName(String(repeating: "x", count: 40))?.count, 24)
    }

    func testSavingKeepsOnlyLookKeys() {
        let s = ["warm": "0.5", "sat": "1.1", "fps": "60", "cap": "4k", "q": "0.9", "evil": "1"]
        let out = Presets.saving("Day", settings: s, into: [:])
        XCTAssertEqual(out?["Day"], ["warm": "0.5", "sat": "1.1"])
    }

    func testLimit() {
        var all: [String: [String: String]] = [:]
        for i in 0..<12 { all = Presets.saving("P\(i)", settings: [:], into: all)! }
        XCTAssertNil(Presets.saving("P12", settings: [:], into: all))       // 13th: refused
        XCTAssertNotNil(Presets.saving("P3", settings: ["sat": "1"], into: all)) // overwrite: fine
        XCTAssertNil(Presets.saving("", settings: [:], into: [:]))
    }

    func testSorted() {
        XCTAssertEqual(Presets.sortedNames(["b": [:], "A": [:], "c": [:]]), ["A", "b", "c"])
    }
}

final class FlickerTests: XCTestCase {
    func testSafeShutters() {
        XCTAssertEqual(Flicker.safeShutter(mains: 50, longest: 1.0 / 30), 0.03, accuracy: 1e-9)
        XCTAssertEqual(Flicker.safeShutter(mains: 50, longest: 1.0 / 60), 0.01, accuracy: 1e-9)
        XCTAssertEqual(Flicker.safeShutter(mains: 60, longest: 1.0 / 30), 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(Flicker.safeShutter(mains: 60, longest: 1.0 / 60), 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(Flicker.safeShutter(mains: 50, longest: 1.0 / 240), 1.0 / 240, accuracy: 1e-12)
    }

    func testSnap() {
        XCTAssertEqual(Flicker.snap(1.0 / 1000, mains: 50, longest: 1.0 / 30), 1.0 / 1000) // too short: untouched
        XCTAssertEqual(Flicker.snap(0.018, mains: 50, longest: 1.0 / 30), 0.02, accuracy: 1e-9)
        XCTAssertEqual(Flicker.snap(1.0 / 30, mains: 50, longest: 1.0 / 30), 0.03, accuracy: 1e-9)
    }

    func testRegions() {
        XCTAssertEqual(Flicker.mainsHz(region: "US"), 60)
        XCTAssertEqual(Flicker.mainsHz(region: "de"), 50)
        XCTAssertEqual(Flicker.mainsHz(region: nil), 50)
    }
}
