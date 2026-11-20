import XCTest
@testable import PhoneCamCore

final class BitrateTests: XCTestCase {
    func testStartsAtTarget() {
        var b = BitrateController(target: 24_000_000)
        XCTAssertEqual(b.tick(now: 0), 24_000_000)
    }

    func testBacksOffOncePerSecond() {
        var b = BitrateController(target: 20_000_000)
        _ = b.tick(now: 0)
        b.reportCongestion(); b.reportCongestion(); b.reportCongestion()
        XCTAssertEqual(b.tick(now: 1), 14_000_000)       // -30% once, however many reports
        XCTAssertEqual(b.tick(now: 1.5), 14_000_000)     // not again within the second
        b.reportCongestion()
        XCTAssertEqual(b.tick(now: 2), 9_800_000)
    }

    func testFloor() {
        var b = BitrateController(target: 3_000_000)
        for s in 1...10 {
            b.reportCongestion()
            _ = b.tick(now: Double(s))
        }
        XCTAssertEqual(b.current, BitrateController.floor)
    }

    func testRecoversAfterFourCleanSecondsAndCapsAtTarget() {
        var b = BitrateController(target: 10_000_000)
        _ = b.tick(now: 0)
        b.reportCongestion()
        XCTAssertEqual(b.tick(now: 1), 7_000_000)
        for s in 2...5 { XCTAssertEqual(b.tick(now: Double(s)), 7_000_000, "second \(s)") } // still within 4 s
        XCTAssertEqual(Double(b.tick(now: 6)), 8_050_000, accuracy: 1) // +15%
        for s in 7...20 { _ = b.tick(now: Double(s)) }
        XCTAssertEqual(b.current, 10_000_000)
    }

    func testLowerTargetAppliesAtOnce() {
        var b = BitrateController(target: 24_000_000)
        _ = b.tick(now: 0)
        b.target = 8_000_000
        XCTAssertEqual(b.tick(now: 0.1), 8_000_000)
    }
}

final class WatchdogTests: XCTestCase {
    func restart(now: Double = 100, watched: Bool = true, asleep: Bool = false, interrupted: Bool = false,
                 lastFrame: Double = 90, lastStart: Double = 80) -> Bool {
        CameraWatchdog.shouldRestart(now: now, watched: watched, asleep: asleep, interrupted: interrupted,
                                     lastFrame: lastFrame, lastStart: lastStart)
    }

    func testRestartsAStalledCamera() { XCTAssertTrue(restart()) }
    func testNotWhileFramesFlow() { XCTAssertFalse(restart(lastFrame: 98)) }
    func testNotRightAfterAStart() { XCTAssertFalse(restart(lastStart: 97)) }
    func testNotWhenNobodyWatches() { XCTAssertFalse(restart(watched: false)) }
    func testNotAsleep() { XCTAssertFalse(restart(asleep: true)) }
    func testNotWhileIOSHoldsIt() { XCTAssertFalse(restart(interrupted: true)) }
}

final class RelayHTTPTests: XCTestCase {
    let get = Data("GET /set?lens=wide HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

    func testRoutes() {
        XCTAssertEqual(RelayHTTP.route(Data("GET /hevc HTTP/1.1\r\n\r\n".utf8)), .camera)
        XCTAssertEqual(RelayHTTP.route(Data("GET /link HTTP/1.1\r\n\r\n".utf8)), .link)
        XCTAssertEqual(RelayHTTP.route(get), .proxy)
        XCTAssertEqual(RelayHTTP.route(Data("POST /hevc HTTP/1.1\r\n\r\n".utf8)), .proxy)
    }

    func testKeyGoesRightAfterTheRequestLine() {
        let out = RelayHTTP.addHeader(get, name: "X-PhoneCam-Key", value: "k1")
        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       "GET /set?lens=wide HTTP/1.1\r\nX-PhoneCam-Key: k1\r\nHost: localhost\r\n\r\n")
    }

    func testBodyKeptByteForByte() {
        let body = Data([0, 1, 2, 0xff, 13, 10])
        let req = Data("POST /set HTTP/1.1\r\nContent-Length: 6\r\n\r\n".utf8) + body
        let out = RelayHTTP.addHeader(req, name: "X-PhoneCam-Key", value: "k")
        XCTAssertEqual(out.suffix(6), body)
        XCTAssertEqual(out.count, req.count + "X-PhoneCam-Key: k\r\n".utf8.count)
    }

    func testUnchangedWithoutKeyOrRequestLine() {
        XCTAssertEqual(RelayHTTP.addHeader(get, name: "X", value: ""), get)
        let partial = Data("GET /state HTTP/1.1".utf8)
        XCTAssertEqual(RelayHTTP.addHeader(partial, name: "X", value: "k"), partial)
    }
}
