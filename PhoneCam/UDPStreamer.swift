import Foundation
import Network
import QuartzCore

/// The camera stream over UDP: a lost packet costs a frame or two (the Mac skips to the next keyframe)
/// instead of stalling everything behind it like TCP does on Wi‑Fi.
///
/// The Mac subscribes by sending "HELLO <key>" to UDP port 4747 every second (from the same socket it reads
/// on); without a hello for 3 s the subscriber is dropped. It may also send "KEY" (lost a frame: send a
/// keyframe) and "LOSS" (the link is dropping packets: lower the bitrate).
///
/// Each HEVC message (see HEVCEncoder) is cut into datagrams:
///   [u8 0x50 'P'][u8 flags: 1 = keyframe][u32 BE frame number][u16 BE index][u16 BE count] + ≤ 1200 bytes
final class UDPStreamer {
    static let chunk = 1200

    var onKeyRequest: (() -> Void)?
    var onLoss: (() -> Void)?

    private final class Sub {
        let conn: NWConnection
        var lastHello = CACurrentMediaTime()
        var needKey = true
        init(_ c: NWConnection) { conn = c }
    }

    private let q = DispatchQueue(label: "udp", qos: .userInteractive)
    private var listener: NWListener?
    private var subs: [ObjectIdentifier: Sub] = [:]   // on q, only subscribers that sent a valid hello
    private var frame: UInt32 = 0
    private let countLock = NSLock()
    private var count = 0
    private let key: String

    var hasSubscribers: Bool { countLock.withLock { count > 0 } }

    init(key: String) { self.key = key }

    func start(port: UInt16) {
        q.async {
            let params = NWParameters.udp
            params.includePeerToPeer = true
            guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
            // Bonjour: the Mac connects by name, which also brings up direct Wi‑Fi (AWDL) between the two.
            l.service = NWListener.Service(name: "PhoneCam", type: "_phonecam._udp")
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed = s { self?.q.asyncAfter(deadline: .now() + 1) { self?.start(port: port) } }
            }
            l.start(queue: self.q)
            self.listener = l
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.expire() }
            t.resume()
            self.timer = t
        }
    }
    private var timer: DispatchSourceTimer?

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) { self.handle(text, from: c) }
            if err == nil { self.receive(c) } else { self.remove(c) }
        }
    }

    private func handle(_ text: String, from c: NWConnection) {
        let id = ObjectIdentifier(c)
        if text.hasPrefix("HELLO") {
            let given = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard key.isEmpty || given == key else { return }
            if let s = subs[id] { s.lastHello = CACurrentMediaTime(); return }
            subs[id] = Sub(c)
            updateCount()
            onKeyRequest?() // the new viewer can start right away
        } else if text == "KEY", let s = subs[id] {
            s.needKey = true
            onKeyRequest?()
        } else if text == "LOSS", subs[id] != nil {
            onLoss?()
        }
    }

    private func expire() {
        let now = CACurrentMediaTime()
        for (id, s) in subs where now - s.lastHello > 3 {
            s.conn.cancel()
            subs[id] = nil
        }
        updateCount()
    }

    private func remove(_ c: NWConnection) {
        subs[ObjectIdentifier(c)] = nil
        c.cancel()
        updateCount()
    }

    private func updateCount() {
        let n = subs.count
        countLock.withLock { count = n }
    }

    /// Any thread: send one encoded frame (config + frame messages) to every subscriber.
    func send(_ msg: Data, isKey: Bool) {
        q.async {
            guard !self.subs.isEmpty else { return }
            self.frame &+= 1
            let n = (msg.count + UDPStreamer.chunk - 1) / UDPStreamer.chunk
            guard n <= Int(UInt16.max) else { return }
            var packets: [Data] = []
            packets.reserveCapacity(n)
            for i in 0..<n {
                var p = Data(capacity: 10 + UDPStreamer.chunk)
                p.append(0x50)
                p.append(isKey ? 1 : 0)
                p.append(contentsOf: withUnsafeBytes(of: self.frame.bigEndian, Array.init))
                p.append(contentsOf: withUnsafeBytes(of: UInt16(i).bigEndian, Array.init))
                p.append(contentsOf: withUnsafeBytes(of: UInt16(n).bigEndian, Array.init))
                let start = msg.startIndex + i * UDPStreamer.chunk
                p.append(msg[start..<min(msg.endIndex, start + UDPStreamer.chunk)])
                packets.append(p)
            }
            let targets = self.subs.values.filter { s in
                if s.needKey && !isKey { return false } // a frame can only follow the frames it depends on
                s.needKey = false
                return true
            }
            // Pace the packets: groups of 16 about 1 ms apart, not one burst that overflows Wi‑Fi buffers.
            let group = 16
            for (g, start) in stride(from: 0, to: packets.count, by: group).enumerated() {
                let slice = packets[start..<min(packets.count, start + group)]
                let send = {
                    for s in targets { s.conn.batch { for p in slice { s.conn.send(content: p, completion: .idempotent) } } }
                }
                if g == 0 { send() } else { self.q.asyncAfter(deadline: .now() + .microseconds(1000 * g), execute: send) }
            }
        }
    }
}
