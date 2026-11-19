import Foundation

/// The camera stream (GET /hevc) after its HTTP header: messages `[u8 type][u32 BE length][payload]`.
/// Type 1 = parameter sets (`[u8 count]` then `[u32 BE size][bytes]` each), type 2 = one access unit
/// (4-byte length-prefixed NAL units).
public enum HEVCWire {
    public static let config: UInt8 = 1
    public static let frame: UInt8 = 2
    /// A longer message means the stream is out of step (or not ours).
    public static let maxLength = 16 << 20
    /// No end of the HTTP header within this many bytes: not our server.
    public static let maxHeader = 16 * 1024

    public static func append(_ d: inout Data, type: UInt8, _ payload: Data) {
        d.append(type)
        appendU32(&d, payload.count)
        d.append(payload)
    }

    public static func parameterSets(_ sets: [Data]) -> Data {
        var out = Data([UInt8(sets.count)])
        for s in sets {
            appendU32(&out, s.count)
            out.append(s)
        }
        return out
    }

    /// The parameter sets of a type-1 payload, or nil if it is malformed.
    public static func splitParameterSets(_ p: Data) -> [Data]? {
        guard let count = p.first, count > 0 else { return nil }
        var sets: [Data] = []
        var i = p.startIndex + 1
        for _ in 0..<Int(count) {
            guard i + 4 <= p.endIndex else { return nil }
            let n = readU32(p, at: i)
            i += 4
            guard n <= p.endIndex - i else { return nil }
            sets.append(Data(p[i..<(i + n)]))
            i += n
        }
        return sets
    }

    static func appendU32(_ d: inout Data, _ v: Int) {
        d.append(contentsOf: withUnsafeBytes(of: UInt32(v).bigEndian, Array.init))
    }

    static func readU32(_ d: Data, at i: Data.Index) -> Int {
        Int(UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3]))
    }

    /// Splits the incoming bytes into messages. Consumed bytes are dropped in bulk, not by copying the rest
    /// of the buffer after every message.
    public struct Reader {
        public enum Failure: Error, Equatable { case notOurServer, garbage }

        private var buffer = Data()
        private var pos = 0          // offset of the first unread byte in `buffer`
        private var inHeader: Bool

        public init(skipHTTPHeader: Bool = true) { inHeader = skipHTTPHeader }

        /// Bytes received but not yet returned as a message.
        public var pending: Int { buffer.count - pos }

        public mutating func feed(_ data: Data) throws -> [(type: UInt8, payload: Data)] {
            buffer.append(data)
            if inHeader {
                let rest = buffer[(buffer.startIndex + pos)...]
                guard let r = rest.range(of: Data("\r\n\r\n".utf8)) else {
                    if pending > HEVCWire.maxHeader { throw Failure.notOurServer }
                    return []
                }
                pos = r.upperBound - buffer.startIndex
                inHeader = false
            }
            var out: [(UInt8, Data)] = []
            while pending >= 5 {
                let b = buffer.startIndex + pos
                let len = HEVCWire.readU32(buffer, at: b + 1)
                guard len < HEVCWire.maxLength else { throw Failure.garbage }
                guard pending >= 5 + len else { break }
                out.append((buffer[b], Data(buffer[(b + 5)..<(b + 5 + len)])))
                pos += 5 + len
            }
            // Drop what was read once it is most of the buffer (one copy of the small rest).
            if pos > 0, pos >= buffer.count / 2 {
                buffer = Data(buffer[(buffer.startIndex + pos)...])
                pos = 0
            }
            return out
        }
    }
}
