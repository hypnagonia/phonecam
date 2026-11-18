import Foundation
import Network
import QuartzCore

/// Receives the camera stream over UDP (see UDPStreamer in the iOS app) and hands out complete frames in
/// order. A frame that doesn't arrive whole within 60 ms of a newer one is given up: frames are skipped until
/// the next keyframe (asked for at once), so a lost packet costs a few frames, never a stall.
final class UDPReceiver {
    /// Called on the relay queue with one frame's messages (config + frame), in order, starting at a keyframe.
    var onFrame: ((Data, Bool) -> Void)?
    private(set) var lastFrameTime = 0.0
    private(set) var started = false

    private let q: DispatchQueue
    private let key: String
    private var conn: NWConnection?
    private var hello: DispatchSourceTimer?
    private var tick: DispatchSourceTimer?

    private struct Partial {
        var parts: [Int: Data] = [:]
        var count: Int
        var isKey: Bool
        var completedAt: Double?
    }
    private var frames: [UInt32: Partial] = [:]
    private var expected: UInt32?      // next frame number to deliver
    private var waitingKey = true      // after a loss (or at start) only a keyframe can be shown
    private var lossTimes: [Double] = []

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
        frames.removeAll()
        expected = nil
        waitingKey = true
        started = false
    }

    /// A new local viewer needs a keyframe to start from.
    func requestKey() { say("KEY") }

    private func say(_ text: String) {
        conn?.send(content: Data(text.utf8), completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, c === self.conn else { return }
            if let data { self.packet(data) }
            if err == nil { self.receive(c) }
        }
    }

    private func packet(_ d: Data) {
        guard d.count > 10, d[d.startIndex] == 0x50 else { return }
        let b = d.startIndex
        let isKey = d[b + 1] & 1 != 0
        let n = UInt32(d[b + 2]) << 24 | UInt32(d[b + 3]) << 16 | UInt32(d[b + 4]) << 8 | UInt32(d[b + 5])
        let idx = Int(UInt16(d[b + 6]) << 8 | UInt16(d[b + 7]))
        let count = Int(UInt16(d[b + 8]) << 8 | UInt16(d[b + 9]))
        guard count > 0, idx < count else { return }
        if let e = expected, n &- e > 0x8000_0000 { return } // older than what we already showed
        var f = frames[n] ?? Partial(count: count, isKey: isKey)
        f.parts[idx] = Data(d[(b + 10)...])
        if f.parts.count == f.count, f.completedAt == nil { f.completedAt = CACurrentMediaTime() }
        frames[n] = f
        deliver()
    }

    /// Deliver complete frames in order; restart at a keyframe after a loss.
    private func deliver() {
        if waitingKey {
            // The newest complete keyframe restarts the stream; everything older is dropped.
            guard let k = frames.filter({ $0.value.isKey && $0.value.completedAt != nil }).keys.max(by: { $1 &- $0 < 0x8000_0000 }) else { return }
            frames = frames.filter { $0.key &- k < 0x8000_0000 }
            expected = k
            waitingKey = false
        }
        while let e = expected, let f = frames[e], f.completedAt != nil {
            var msg = Data()
            for i in 0..<f.count { msg.append(f.parts[i]!) }
            frames[e] = nil
            expected = e &+ 1
            lastFrameTime = CACurrentMediaTime()
            onFrame?(msg, f.isKey)
        }
    }

    /// The expected frame is missing while a newer one has been complete for 60 ms: give it up.
    private func checkLoss() {
        guard !waitingKey, let e = expected else { return }
        let now = CACurrentMediaTime()
        let newerDone = frames.contains { $0.key &- e < 0x8000_0000 && $0.key != e && ($0.value.completedAt.map { now - $0 > 0.06 } ?? false) }
        let stale = frames.values.contains { $0.completedAt == nil } && now - lastFrameTime > 0.5
        guard newerDone || stale else { return }
        waitingKey = true
        frames = frames.filter { $0.value.isKey }
        say("KEY")
        // One loss is Wi‑Fi noise; repeated losses mean the bitrate is too high for the link.
        lossTimes = lossTimes.filter { now - $0 < 3 } + [now]
        if lossTimes.count >= 2 { say("LOSS"); lossTimes.removeAll() }
        deliver()
    }
}
