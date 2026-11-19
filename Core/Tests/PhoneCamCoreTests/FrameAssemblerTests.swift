import XCTest
@testable import PhoneCamCore

final class FrameAssemblerTests: XCTestCase {
    /// A message of `size` bytes whose content tells the frame apart.
    private func message(_ n: UInt32, size: Int = 3000) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: Int(n) &* 31 &+ $0) }) }

    private func frames(_ events: [FrameAssembler.Event]) -> [Data] {
        events.compactMap { if case let .frame(d, _) = $0 { return d } else { return nil } }
    }

    func testPacketRoundTrip() {
        let msg = message(7, size: 2500)
        let ps = UDPPacket.packets(of: msg, frame: 7, isKey: true)
        XCTAssertEqual(ps.count, 3)
        let parsed = ps.compactMap(UDPPacket.parse)
        XCTAssertEqual(parsed.map(\.0), (0..<3).map { UDPPacket.Header(isKey: true, frame: 7, index: $0, count: 3) })
        XCTAssertEqual(parsed.reduce(Data()) { $0 + $1.1 }, msg)
        XCTAssertNil(UDPPacket.parse(Data([0x51] + Array(repeating: 0, count: 20))))
        XCTAssertNil(UDPPacket.parse(Data([0x50, 0, 0, 0, 0, 1, 0, 5, 0, 3, 9]))) // index ≥ count
    }

    func testShuffledPacketsComeOutInOrder() {
        var a = FrameAssembler()
        var all: [Data] = []
        for n in UInt32(1)...5 { all += UDPPacket.packets(of: message(n), frame: n, isKey: n == 1) }
        var rng = SystemRandomNumberGenerator()
        // Shuffle only within a window of 4 packets, like Wi‑Fi reordering.
        for i in stride(from: 0, to: all.count - 3, by: 4) { all[i..<i + 4].shuffle(using: &rng) }
        var got: [Data] = []
        for (i, p) in all.enumerated() { got += frames(a.packet(p, now: Double(i) * 0.001)) }
        XCTAssertEqual(got, (UInt32(1)...5).map { message($0) })
    }

    func testStartsOnlyAtAKeyframe() {
        var a = FrameAssembler()
        var events: [FrameAssembler.Event] = []
        for p in UDPPacket.packets(of: message(1), frame: 1, isKey: false) { events += a.packet(p, now: 0) }
        XCTAssertTrue(frames(events).isEmpty)
        for p in UDPPacket.packets(of: message(2), frame: 2, isKey: true) { events += a.packet(p, now: 0.01) }
        XCTAssertEqual(frames(events), [message(2)])
    }

    func testLostPacketSkipsToNextKeyframe() {
        var a = FrameAssembler()
        var got: [Data] = [], asks: [FrameAssembler.Event] = []
        func feed(_ n: UInt32, key: Bool, drop: Int? = nil, at t: Double) {
            for (i, p) in UDPPacket.packets(of: message(n), frame: n, isKey: key).enumerated() where i != drop {
                got += frames(a.packet(p, now: t))
            }
        }
        feed(1, key: true, at: 0)
        feed(2, key: false, drop: 1, at: 0.033)   // frame 2 loses a packet
        feed(3, key: false, at: 0.066)            // 3 depends on 2: can't be shown
        asks += a.tick(now: 0.2)                  // 3 complete for > 60 ms → give up, ask for a key
        XCTAssertEqual(asks, [.requestKey])
        feed(4, key: false, at: 0.21)             // still waiting for a keyframe
        feed(5, key: true, at: 0.24)
        XCTAssertEqual(got, [message(1), message(5)])
    }

    func testRepeatedLossesReportLoss() {
        var a = FrameAssembler()
        var events: [FrameAssembler.Event] = []
        var t = 0.0
        for round in 0..<2 {
            let base = UInt32(round * 10 + 1)
            for p in UDPPacket.packets(of: message(base), frame: base, isKey: true) { _ = a.packet(p, now: t) }
            for p in UDPPacket.packets(of: message(base + 1), frame: base + 1, isKey: false).dropFirst() { _ = a.packet(p, now: t) }
            for p in UDPPacket.packets(of: message(base + 2), frame: base + 2, isKey: false) { _ = a.packet(p, now: t) }
            t += 0.1
            events += a.tick(now: t)
        }
        XCTAssertEqual(events, [.requestKey, .requestKey, .reportLoss])
    }

    func testFrameNumberWrapAround() {
        var a = FrameAssembler()
        var got: [Data] = []
        for n in [UInt32.max - 1, UInt32.max, 0, 1] {
            for p in UDPPacket.packets(of: message(n), frame: n, isKey: n == UInt32.max - 1) { got += frames(a.packet(p, now: 0)) }
        }
        XCTAssertEqual(got.count, 4)
    }
}
