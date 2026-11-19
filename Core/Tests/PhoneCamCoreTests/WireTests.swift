import XCTest
@testable import PhoneCamCore

final class HEVCWireTests: XCTestCase {
    let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-phonecam-hevc\r\nConnection: close\r\n\r\n".utf8)

    func stream(_ msgs: [(UInt8, Data)]) -> Data {
        var d = Data()
        for (t, p) in msgs { HEVCWire.append(&d, type: t, p) }
        return d
    }

    func testRoundTripInOnePiece() throws {
        let vps = Data([0x40, 1, 2]), sps = Data([0x42, 3, 4, 5]), pps = Data([0x44, 6])
        let cfg = HEVCWire.parameterSets([vps, sps, pps])
        let frame = Data((0..<5000).map { UInt8($0 & 0xff) })
        var r = HEVCWire.Reader()
        let got = try r.feed(header + stream([(HEVCWire.config, cfg), (HEVCWire.frame, frame)]))
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].type, HEVCWire.config)
        XCTAssertEqual(HEVCWire.splitParameterSets(got[0].payload), [vps, sps, pps])
        XCTAssertEqual(got[1].type, HEVCWire.frame)
        XCTAssertEqual(got[1].payload, frame)
        XCTAssertEqual(r.pending, 0)
    }

    func testByteByByte() throws {
        let frames = (1...5).map { n in Data(repeating: UInt8(n), count: n * 300) }
        let all = header + stream(frames.map { (HEVCWire.frame, $0) })
        var r = HEVCWire.Reader()
        var got: [Data] = []
        for b in all { got += try r.feed(Data([b])).map(\.payload) }
        XCTAssertEqual(got, frames)
        XCTAssertEqual(r.pending, 0)
    }

    func testRandomChunks() throws {
        var rng = SystemRandomNumberGenerator()
        let frames = (0..<50).map { _ in Data((0..<Int.random(in: 0...20000, using: &rng)).map { _ in UInt8.random(in: 0...255) }) }
        let all = header + stream(frames.map { (HEVCWire.frame, $0) })
        var r = HEVCWire.Reader()
        var got: [Data] = []
        var i = 0
        while i < all.count {
            let n = min(all.count - i, Int.random(in: 1...70000, using: &rng))
            got += try r.feed(all.subdata(in: i..<(i + n))).map(\.payload)
            i += n
        }
        XCTAssertEqual(got, frames)
    }

    func testHeaderSplitAcrossReads() throws {
        var r = HEVCWire.Reader()
        let body = stream([(HEVCWire.frame, Data([9, 9]))])
        XCTAssertTrue(try r.feed(header.prefix(header.count - 2)).isEmpty)
        let got = try r.feed(header.suffix(2) + body)
        XCTAssertEqual(got.map(\.payload), [Data([9, 9])])
    }

    func testNotOurServer() {
        var r = HEVCWire.Reader()
        XCTAssertThrowsError(try r.feed(Data(repeating: 0x41, count: HEVCWire.maxHeader + 1))) {
            XCTAssertEqual($0 as? HEVCWire.Reader.Failure, .notOurServer)
        }
    }

    func testGarbageLength() {
        var r = HEVCWire.Reader(skipHTTPHeader: false)
        XCTAssertThrowsError(try r.feed(Data([2, 0xff, 0xff, 0xff, 0xff]))) {
            XCTAssertEqual($0 as? HEVCWire.Reader.Failure, .garbage)
        }
    }

    func testMalformedParameterSets() {
        XCTAssertNil(HEVCWire.splitParameterSets(Data()))
        XCTAssertNil(HEVCWire.splitParameterSets(Data([0])))
        XCTAssertNil(HEVCWire.splitParameterSets(Data([1, 0, 0, 0, 5, 1, 2])))  // size past the end
        XCTAssertNil(HEVCWire.splitParameterSets(Data([2, 0, 0, 0, 1, 7])))     // second set missing
        XCTAssertEqual(HEVCWire.splitParameterSets(Data([1, 0, 0, 0, 1, 7])), [Data([7])])
    }
}

final class ARPTests: XCTestCase {
    func testLinkLocalFromRealOutput() {
        let text = """
        ? (192.168.1.1) at 3c:52:a1:0:0:1 on en0 ifscope [ethernet]
        ? (169.254.210.150) at ce:5:a5:b6:8a:61 on en6 [ethernet]
        ? (169.254.255.255) at ff:ff:ff:ff:ff:ff on en6 [ethernet]
        ? (169.254.12.7) at (incomplete) on en0 [ethernet]
        ? (169.254.3.255) at 1:2:3:4:5:6 on en7 [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (169.254.210.150) at ce:5:a5:b6:8a:61 on en6 [ethernet]
        ? (169.254.40.2) at a:b:c:d:e:f on en8 [ethernet]
        """
        XCTAssertEqual(ARP.linkLocal(text), ["169.254.210.150", "169.254.40.2"])
    }

    func testEmpty() {
        XCTAssertEqual(ARP.linkLocal(""), [])
        XCTAssertEqual(ARP.linkLocal("garbage\n(\n)"), [])
    }
}
