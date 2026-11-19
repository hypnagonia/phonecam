import Foundation
import Network
import QuartzCore
import PhoneCamCore

/// Receives the camera stream over UDP (see UDPStreamer in the iOS app). Putting packets back into frames,
/// in order, with loss handling, is `FrameAssembler` (PhoneCamCore); this class is only the network side.
///
/// Network.framework picks the route (cable or direct Wi‑Fi, never the router). Once it is up, the packets
/// are read from a plain socket bound to that same interface, all waiting packets at each wake-up, instead
/// of one callback per packet (~1100 a second): several times less CPU. If nothing arrives on the socket
/// within 1.5 s, it goes back to Network.framework.
final class UDPReceiver {
    /// Called on the relay queue with one frame's messages (config + frame), in order, starting at a keyframe.
    var onFrame: ((Data, Bool) -> Void)?
    var lastFrameTime: Double { assembler.lastFrameTime }
    private(set) var started = false

    private let q: DispatchQueue
    private let key: String
    private var conn: NWConnection?
    private var hello: DispatchSourceTimer?
    private var tick: DispatchSourceTimer?

    private var assembler = FrameAssembler()
    private var fd: Int32 = -1                 // the fast socket, -1 when not in use
    private var readSource: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 65536)
    private var socketPackets = 0              // packets read on the fast socket since it opened
    private var noFastPath = false             // the socket gave nothing once: stay on Network.framework
    private(set) var mode = "–"                // "socket" or "network", for diagnostics

    init(queue: DispatchQueue, key: String) {
        q = queue
        self.key = key
    }

    /// q: subscribe to the phone at `endpoint` (its Bonjour UDP service, or host:4747).
    /// `avoid`: the Mac's Wi‑Fi to the router, never used: only the cable or direct Wi‑Fi (AWDL).
    func start(endpoint: NWEndpoint, via: NWInterface? = nil, avoid: NWInterface?) {
        stop()
        started = true
        let params = NWParameters.udp
        params.includePeerToPeer = true
        if let via { params.requiredInterface = via }
        if let avoid { params.prohibitedInterfaces = [avoid] }
        let c = NWConnection(to: endpoint, using: params)
        conn = c
        mode = "network"
        c.stateUpdateHandler = { [weak self] st in
            guard let self, c === self.conn, case .ready = st, !self.noFastPath, self.fd < 0 else { return }
            self.openSocket(like: c, endpoint: endpoint, via: via, avoid: avoid)
        }
        c.start(queue: q)
        receive(c)
        let h = DispatchSource.makeTimerSource(queue: q)
        h.schedule(deadline: .now(), repeating: 1)
        h.setEventHandler { [weak self] in self?.say("HELLO \(self?.key ?? "")") }
        h.resume()
        hello = h
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02)
        t.setEventHandler { [weak self] in self?.checkLoss() }
        t.resume()
        tick = t
    }

    func stop() {
        hello?.cancel(); hello = nil
        tick?.cancel(); tick = nil
        conn?.cancel(); conn = nil
        closeSocket()
        assembler.reset()
        started = false
    }

    /// A local viewer (new, or one that fell behind) needs a keyframe to start from. The stream itself is
    /// fine, so the phone keeps sending every frame ("KEY" is only for real losses). At most once a second:
    /// a viewer that keeps lagging must not turn the whole stream into keyframes.
    func requestKey() {
        let now = CACurrentMediaTime()
        guard now - lastIDR > 1 else { return }
        lastIDR = now
        say("IDR")
    }
    private var lastIDR = 0.0

    private func say(_ text: String) {
        if fd >= 0 {
            _ = text.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
        } else {
            conn?.send(content: Data(text.utf8), completion: .idempotent)
        }
    }

    // MARK: fast path

    /// q: a plain UDP socket to the address and over the interface the connection `c` uses.
    private func openSocket(like c: NWConnection, endpoint: NWEndpoint, via: NWInterface?, avoid: NWInterface?) {
        guard let path = c.currentPath, case let .hostPort(host, port)? = path.remoteEndpoint,
              let iface = path.availableInterfaces.first, iface.name != avoid?.name else { return }
        let s: Int32
        var ok = false
        switch host {
        case .ipv6(let a):
            s = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else { return }
            var idx = UInt32(iface.index)
            setsockopt(s, IPPROTO_IPV6, IPV6_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_port = port.rawValue.bigEndian
            withUnsafeMutableBytes(of: &sa.sin6_addr) { $0.copyBytes(from: a.rawValue) }
            sa.sin6_scope_id = UInt32(iface.index)
            ok = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        case .ipv4(let a):
            s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else { return }
            var idx = UInt32(iface.index)
            setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.rawValue.bigEndian
            withUnsafeMutableBytes(of: &sa.sin_addr) { $0.copyBytes(from: a.rawValue) }
            ok = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        default:
            return
        }
        guard ok else { close(s); return }
        var size: Int32 = 4 << 20 // room for a big keyframe even if the queue is busy for a moment
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        socketPackets = 0
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(s) }
        src.resume()
        readSource = src
        say("HELLO \(key)")
        // Nothing on the socket in 1.5 s (a route it can't use): back to Network.framework for good.
        q.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.fd == s else { return }
            if self.socketPackets == 0 {
                self.noFastPath = true
                self.closeSocket()
                self.mode = "network"
            } else {
                self.mode = "socket"
                self.conn?.cancel() // the phone drops that subscription after 3 s without a hello
                self.conn = nil
            }
        }
    }

    /// q: every packet waiting on the socket, in one go.
    private func drain() {
        let now = CACurrentMediaTime()
        var events: [FrameAssembler.Event] = []
        while fd >= 0 {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            socketPackets += 1
            events += assembler.packet(Data(buffer[0..<n]), now: now)
        }
        handle(events)
    }

    private func closeSocket() {
        readSource?.cancel(); readSource = nil
        fd = -1
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, c === self.conn else { return }
            if let data, self.fd < 0 || self.socketPackets == 0 { self.packet(data) }
            if err == nil { self.receive(c) }
        }
    }

    private func packet(_ d: Data) {
        handle(assembler.packet(d, now: CACurrentMediaTime()))
    }

    private func checkLoss() {
        handle(assembler.tick(now: CACurrentMediaTime()))
    }

    private func handle(_ events: [FrameAssembler.Event]) {
        for e in events {
            switch e {
            case let .frame(msg, isKey): onFrame?(msg, isKey)
            case .requestKey: say("KEY")
            case .reportLoss: say("LOSS")
            }
        }
    }
}
