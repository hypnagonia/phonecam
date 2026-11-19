import Foundation

/// Puts UDP packets back into whole frames and hands them out in order. A frame that doesn't arrive whole
/// within 60 ms of a newer complete one is given up: frames are skipped until the next keyframe (asked for
/// at once), so a lost packet costs a few frames, never a stall. Time is passed in, so this is testable.
public struct FrameAssembler {
    public enum Event: Equatable {
        case frame(Data, isKey: Bool)   // one frame's messages, in order, starting at a keyframe
        case requestKey                 // send "KEY": we need a keyframe to go on
        case reportLoss                 // send "LOSS": repeated losses, the bitrate is too high for the link
    }

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
    public private(set) var lastFrameTime = 0.0

    public init() {}

    public mutating func reset() {
        frames.removeAll()
        expected = nil
        waitingKey = true
    }

    /// Wrap-around order of frame numbers: is `a` at or after `b`?
    private static func notBefore(_ a: UInt32, _ b: UInt32) -> Bool { a &- b < 0x8000_0000 }

    public mutating func packet(_ d: Data, now: Double) -> [Event] {
        guard let (h, payload) = UDPPacket.parse(d) else { return [] }
        if let e = expected, !Self.notBefore(h.frame, e) { return [] } // older than what we already showed
        var f = frames[h.frame] ?? Partial(count: h.count, isKey: h.isKey)
        guard f.count == h.count else { return [] }
        f.parts[h.index] = payload
        if f.parts.count == f.count, f.completedAt == nil { f.completedAt = now }
        frames[h.frame] = f
        return deliver(now: now)
    }

    /// Call every ~20 ms: gives up a frame that is missing while a newer one has been complete for 60 ms,
    /// or one that has been stuck incomplete for 0.5 s.
    public mutating func tick(now: Double) -> [Event] {
        guard !waitingKey, let e = expected else { return [] }
        let newerDone = frames.contains { $0.key != e && Self.notBefore($0.key, e) && ($0.value.completedAt.map { now - $0 > 0.06 } ?? false) }
        let stale = frames.values.contains { $0.completedAt == nil } && now - lastFrameTime > 0.5
        guard newerDone || stale else { return [] }
        waitingKey = true
        frames = frames.filter { $0.value.isKey }
        var events: [Event] = [.requestKey]
        // One loss is Wi‑Fi noise; repeated losses mean the bitrate is too high for the link.
        lossTimes = lossTimes.filter { now - $0 < 3 } + [now]
        if lossTimes.count >= 2 { events.append(.reportLoss); lossTimes.removeAll() }
        return events + deliver(now: now)
    }

    private mutating func deliver(now: Double) -> [Event] {
        if waitingKey {
            // The newest complete keyframe restarts the stream; everything older is dropped.
            let keys = frames.filter { $0.value.isKey && $0.value.completedAt != nil }.keys
            guard let k = keys.max(by: { Self.notBefore($1, $0) && $1 != $0 }) else { return [] }
            frames = frames.filter { Self.notBefore($0.key, k) }
            expected = k
            waitingKey = false
        }
        var out: [Event] = []
        while let e = expected, let f = frames[e], f.completedAt != nil {
            var msg = Data()
            for i in 0..<f.count { msg.append(f.parts[i]!) }
            frames[e] = nil
            expected = e &+ 1
            lastFrameTime = now
            out.append(.frame(msg, isKey: f.isKey))
        }
        return out
    }
}
