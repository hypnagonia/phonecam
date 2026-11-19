import Foundation

/// Adaptive bitrate: once a second, back off 30% after any congestion, creep up 15% after 4 s without it;
/// never above the Quality slider's target, never below `floor`.
public struct BitrateController {
    public static let floor = 2_000_000
    public var target: Int                 // from the Quality slider
    public private(set) var current: Int
    private var congestion = 0
    private var lastAdapt = 0.0, cleanSince = 0.0

    public init(target: Int) {
        self.target = target
        current = target
    }

    /// A viewer was still busy with the previous frame (the link is too slow for this bitrate).
    public mutating func reportCongestion() { congestion += 1 }

    /// Per frame: the bitrate to use now.
    public mutating func tick(now: Double) -> Int {
        if now - lastAdapt >= 1 {
            lastAdapt = now
            if congestion > 0 {
                current = max(BitrateController.floor, Int(Double(current) * 0.7))
                cleanSince = now
            } else if now - cleanSince > 4 {
                current = Int(Double(current) * 1.15)
            }
            congestion = 0
        }
        current = min(current, target)
        return current
    }
}

/// When to start the iPhone camera again although iOS reported nothing: someone watches, the camera is
/// meant to run (not asleep, not interrupted), yet no frame came for `stall` seconds, and the last start
/// was at least `grace` seconds ago (a starting camera takes a moment, and restarts must not pile up).
public enum CameraWatchdog {
    public static let stall = 3.0
    public static let grace = 5.0

    public static func shouldRestart(now: Double, watched: Bool, asleep: Bool, interrupted: Bool,
                                     lastFrame: Double, lastStart: Double) -> Bool {
        watched && !asleep && !interrupted && now - lastFrame > stall && now - lastStart > grace
    }
}

/// The Mac relay's view of a request head.
public enum RelayHTTP {
    public enum Route: Equatable { case camera, link, proxy }

    public static func route(_ head: Data) -> Route {
        if head.starts(with: Data("GET /hevc".utf8)) { return .camera }
        if head.starts(with: Data("GET /link".utf8)) { return .link }
        return .proxy
    }

    /// `name: value` added right after the request line (the rest of the head is kept byte for byte).
    /// Without a complete request line, or with an empty value, the head is returned unchanged.
    public static func addHeader(_ head: Data, name: String, value: String) -> Data {
        guard !value.isEmpty, let line = head.range(of: Data("\r\n".utf8)) else { return head }
        return Data(head[..<line.upperBound]) + Data("\(name): \(value)\r\n".utf8) + head[line.upperBound...]
    }
}
