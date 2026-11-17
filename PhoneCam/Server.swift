import Foundation
import Network

/// Tiny HTTP server: control page, MJPEG stream, JSON settings API.
final class Server {
    let port: UInt16
    private let cam: Camera
    private let q = DispatchQueue(label: "srv")
    private var listener: NWListener?

    private final class Client {
        let conn: NWConnection
        var busy = false
        init(_ c: NWConnection) { conn = c }
    }
    private var clients: [ObjectIdentifier: Client] = [:] // touched on q
    private let countLock = NSLock()
    private var count = 0
    var clientCount: Int { countLock.withLock { count } }

    init(port: UInt16, cam: Camera) {
        self.port = port
        self.cam = cam
        cam.wantsFrames = { [weak self] in (self?.clientCount ?? 0) > 0 }
        cam.onFrame = { [weak self] data in self?.broadcast(data) }
    }

    func start() {
        q.async { self.listen() }
    }

    private func listen() {
        listener?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // send each frame's tail at once instead of waiting for an ACK
        guard let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.q.asyncAfter(deadline: .now() + 1) { self?.listen() } }
        }
        l.start(queue: q)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        readRequest(c, Data())
    }

    private func readRequest(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.route(c, String(decoding: buf[..<r.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 65536 {
                c.cancel()
            } else {
                self.readRequest(c, buf)
            }
        }
    }

    private func route(_ c: NWConnection, _ head: String) {
        let first = head.split(separator: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: "http://x" + parts[1]) else {
            return reply(c, "400 Bad Request", "text/plain", Data("bad request".utf8))
        }
        var params: [String: String] = [:]
        for item in url.queryItems ?? [] { params[item.name] = item.value ?? "" }

        switch url.path {
        case "/":
            reply(c, "200 OK", "text/html; charset=utf-8", Data(Page.control.utf8))
        case "/obs":
            reply(c, "200 OK", "text/html; charset=utf-8", Data(Page.obs.utf8))
        case "/video":
            startStream(c)
        case "/state", "/set":
            let st: [String: Any] = cam.queue.sync {
                if url.path == "/set" { cam.apply(params) }
                var s = cam.state()
                s["clients"] = clientCount
                return s
            }
            let json = (try? JSONSerialization.data(withJSONObject: st)) ?? Data("{}".utf8)
            reply(c, "200 OK", "application/json", json)
        default:
            reply(c, "404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    private func reply(_ c: NWConnection, _ status: String, _ type: String, _ body: Data) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: MJPEG

    private func startStream(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        let client = Client(c)
        let id = ObjectIdentifier(client)
        clients[id] = client
        updateCount()
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.drop(id) }
        })
        // Detect the browser closing the stream.
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { self?.drop(id) }
        }
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let cl = clients.removeValue(forKey: id) else { return }
        cl.conn.cancel()
        updateCount()
    }

    private func updateCount() {
        let n = clients.count
        countLock.withLock { count = n }
    }

    private func broadcast(_ jpeg: Data) {
        q.async {
            guard !self.clients.isEmpty else { return }
            var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            part.append(jpeg)
            part.append(Data("\r\n".utf8))
            for (id, cl) in self.clients where !cl.busy {
                cl.busy = true // a slow client skips frames instead of piling them up
                cl.conn.send(content: part, completion: .contentProcessed { [weak self] err in
                    self?.q.async {
                        cl.busy = false
                        if err != nil { self?.drop(id) }
                    }
                })
            }
        }
    }
}
