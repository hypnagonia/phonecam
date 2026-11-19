import Foundation

/// Datagram format of the camera stream. Each HEVC message is cut into packets:
///   [u8 0x50 'P'][u8 flags: 1 = keyframe][u32 BE frame number][u16 BE index][u16 BE count] + ≤ `chunk` bytes
public enum UDPPacket {
    public static let chunk = 1200
    public static let headerSize = 10

    public struct Header: Equatable {
        public var isKey: Bool
        public var frame: UInt32
        public var index: Int
        public var count: Int
    }

    /// The packets for one message; empty when it would need more than 65535 of them.
    public static func packets(of msg: Data, frame: UInt32, isKey: Bool, chunk: Int = UDPPacket.chunk) -> [Data] {
        let n = max(1, (msg.count + chunk - 1) / chunk)
        guard n <= Int(UInt16.max) else { return [] }
        var out: [Data] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            var p = Data(capacity: headerSize + chunk)
            p.append(0x50)
            p.append(isKey ? 1 : 0)
            p.append(contentsOf: withUnsafeBytes(of: frame.bigEndian, Array.init))
            p.append(contentsOf: withUnsafeBytes(of: UInt16(i).bigEndian, Array.init))
            p.append(contentsOf: withUnsafeBytes(of: UInt16(n).bigEndian, Array.init))
            let start = msg.startIndex + i * chunk
            p.append(msg[start..<min(msg.endIndex, start + chunk)])
            out.append(p)
        }
        return out
    }

    /// Header and payload of a packet; nil for anything that isn't one.
    public static func parse(_ d: Data) -> (Header, Data)? {
        guard d.count > headerSize, d[d.startIndex] == 0x50 else { return nil }
        let b = d.startIndex
        let n = UInt32(d[b + 2]) << 24 | UInt32(d[b + 3]) << 16 | UInt32(d[b + 4]) << 8 | UInt32(d[b + 5])
        let idx = Int(UInt16(d[b + 6]) << 8 | UInt16(d[b + 7]))
        let count = Int(UInt16(d[b + 8]) << 8 | UInt16(d[b + 9]))
        guard count > 0, idx < count else { return nil }
        return (Header(isKey: d[b + 1] & 1 != 0, frame: n, index: idx, count: count), Data(d[(b + headerSize)...]))
    }
}
