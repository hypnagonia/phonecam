import Foundation
import Network
import QuartzCore

/// Reads the MJPEG stream (GET /video) over a plain TCP connection and hands out each JPEG.
/// Reconnects after errors, and when no frame arrives for 2 s.
final class MJPEGClient {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue: DispatchQueue
    private let onFrame: (Data) -> Void
    private var conn: NWConnection?
    private var buffer = Data()
    private var need = -1          // bytes of the current JPEG, -1 while reading a header
    private var lastFrame = 0.0
    private var running = false
    private var watchdog: DispatchSourceTimer?

    init(host: String, port: UInt16, queue: DispatchQueue, onFrame: @escaping (Data) -> Void) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.queue = queue
        self.onFrame = onFrame
    }

    // All methods run on `queue`.

    func start() {
        running = true
        connect()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.running, CACurrentMediaTime() - self.lastFrame > 2 else { return }
            self.reconnect()
        }
        t.resume()
        watchdog = t
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        conn?.cancel()
        conn = nil
    }

    private func connect() {
        guard running else { return }
        buffer.removeAll(keepingCapacity: true)
        need = -1
        lastFrame = CACurrentMediaTime()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let c = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.scheduleReconnect(for: c)
            default: break
            }
        }
        c.start(queue: queue)
        c.send(content: Data("GET /video HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n".utf8),
               completion: .contentProcessed { _ in })
        read(c)
    }

    private func reconnect() {
        conn?.cancel() // the state handler schedules the new connection
    }

    private func scheduleReconnect(for c: NWConnection) {
        guard c === conn else { return }
        conn = nil
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running, self.conn == nil else { return }
            self.connect()
        }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if done || err != nil {
                c.cancel()
            } else {
                self.read(c)
            }
        }
    }

    /// Header blocks end with \r\n\r\n. The first one is the HTTP response (no Content-Length);
    /// each multipart header carries the JPEG length.
    private func parse() {
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if need < 0 {
                guard let r = buffer.range(of: sep) else {
                    if buffer.count > 64 * 1024 { buffer.removeAll() } // garbage
                    return
                }
                let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                if let line = head.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let n = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) {
                    need = n
                }
                continue
            }
            guard buffer.count >= need else { return }
            let jpeg = buffer.prefix(need)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + need)
            need = -1
            lastFrame = CACurrentMediaTime()
            onFrame(Data(jpeg))
        }
    }
}
