import Foundation
import Network

/// Tiny HTTP server: control page, MJPEG stream (/video), HEVC stream (/hevc), JSON settings API.
final class Server {
    let port: UInt16
    private let cam: Camera
    private let q = DispatchQueue(label: "srv")
    private var listener: NWListener?

    private final class Client {
        let conn: NWConnection
        var busy = false
        var skipUntilKey = true // HEVC: a frame can only follow the frames it depends on
        var preview = false     // MJPEG: small preview frames for the control page
        init(_ c: NWConnection) { conn = c }
    }
    private var clients: [ObjectIdentifier: Client] = [:]     // MJPEG, touched on q
    private var hevcClients: [ObjectIdentifier: Client] = [:] // HEVC, touched on q
    private let countLock = NSLock()
    private var counts = (jpeg: 0, hevc: 0, preview: 0)
    var clientCount: Int { countLock.withLock { counts.jpeg + counts.hevc } }

    init(port: UInt16, cam: Camera) {
        self.port = port
        self.cam = cam
        cam.wantsJPEG = { [weak self] in (self?.countLock.withLock { self?.counts.jpeg ?? 0 } ?? 0) > 0 }
        cam.wantsPreview = { [weak self] in (self?.countLock.withLock { self?.counts.preview ?? 0 } ?? 0) > 0 }
        cam.wantsHEVC = { [weak self] in
            guard let self else { return false }
            return self.countLock.withLock { self.counts.hevc } > 0 || self.udp.hasSubscribers
        }
        cam.onFrame = { [weak self] data, preview in self?.broadcast(data, preview: preview) }
        cam.encoder.onOutput = { [weak self] msg, isKey in
            self?.broadcastHEVC(msg, isKey: isKey)
            self?.udp.send(msg, isKey: isKey)
        }
        udp.onKeyRequest = { [weak cam] in cam?.encoder.requestKeyframe() }
        udp.onLoss = { [weak cam] in cam?.encoder.reportCongestion() }
    }

    /// The camera stream over UDP (preferred by the Mac app; /hevc over TCP stays as the fallback).
    private let udp = UDPStreamer(key: Server.key)

    func start() {
        q.async { self.listen() }
        udp.start(port: port)
    }

    private func listen() {
        listener?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // send each frame's tail at once instead of waiting for an ACK
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true // also reachable over direct Wi‑Fi (AWDL), like AirDrop: no router hop
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        // Bonjour, so the Mac app finds the phone over USB or Wi‑Fi without knowing its address.
        l.service = NWListener.Service(name: "PhoneCam", type: "_phonecam._tcp")
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
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                self.route(c, head)
            } else if done || err != nil || buf.count > 65536 {
                c.cancel()
            } else {
                self.readRequest(c, buf)
            }
        }
    }

    /// Shared secret from the build (Local.xcconfig → Info.plist). Every request must carry it, so nobody
    /// else on the Wi‑Fi (or nearby over direct Wi‑Fi) can watch the camera or change settings. The Mac app
    /// adds it to every request it relays; without a configured key the server stays open.
    static let key: String = {
        let k = (Bundle.main.object(forInfoDictionaryKey: "PhoneCamKey") as? String) ?? ""
        return k.hasPrefix("$(") ? "" : k
    }()

    private func route(_ c: NWConnection, _ head: String) {
        let lines = head.split(separator: "\r\n")
        let first = lines.first ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: "http://x" + parts[1]) else {
            return reply(c, "400 Bad Request", "text/plain", Data("bad request".utf8))
        }
        var params: [String: String] = [:]
        for item in url.queryItems ?? [] { params[item.name] = item.value ?? "" }
        if !Server.key.isEmpty {
            let header = lines.dropFirst().first { $0.lowercased().hasPrefix("x-phonecam-key:") }
            let given = header.map { String($0.dropFirst("x-phonecam-key:".count)).trimmingCharacters(in: .whitespaces) }
            guard given == Server.key else {
                return reply(c, "403 Forbidden", "text/plain", Data("Open PhoneCam through the Mac app (http://localhost:4747).".utf8))
            }
        }

        switch url.path {
        case "/":
            reply(c, "200 OK", "text/html; charset=utf-8", Data(Page.control.utf8))
        case "/obs":
            reply(c, "200 OK", "text/html; charset=utf-8", Data(Page.obs.utf8))
        case "/video":
            startStream(c, preview: params["preview"] == "1")
        case "/hevc":
            startHEVC(c)
        case "/state", "/set":
            let st: [String: Any] = cam.queue.sync {
                if url.path == "/set" { cam.apply(params) }
                var s = cam.state()
                s["clients"] = clientCount
                let c = countLock.withLock { counts }
                s["viewers"] = "camera \(c.hevc + udp.subscriberCount) · preview \(c.preview) · full JPEG \(c.jpeg)"
                s["mbps"] = (Double(cam.encoder.currentBitrate) / 100_000).rounded() / 10
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

    private func startStream(_ c: NWConnection, preview: Bool) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        let client = Client(c)
        client.preview = preview
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
        guard let cl = clients.removeValue(forKey: id) ?? hevcClients.removeValue(forKey: id) else { return }
        cl.conn.cancel()
        updateCount()
    }

    private func updateCount() {
        let pv = clients.values.filter(\.preview).count
        let c = (jpeg: clients.count - pv, hevc: hevcClients.count, preview: pv)
        countLock.withLock { counts = c }
    }

    // MARK: HEVC

    private func startHEVC(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-phonecam-hevc\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let client = Client(c)
        let id = ObjectIdentifier(client)
        hevcClients[id] = client
        updateCount()
        cam.encoder.requestKeyframe() // the new viewer can start right away
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.drop(id) }
        })
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

    /// A client still sending the previous frame misses this one, so it must wait for the next keyframe
    /// (and asks for one) instead of decoding garbage.
    private func broadcastHEVC(_ msg: Data, isKey: Bool) {
        q.async {
            var needKey = false
            for (id, cl) in self.hevcClients {
                if cl.skipUntilKey && !isKey { continue }
                if cl.busy { cl.skipUntilKey = true; needKey = true; continue }
                cl.skipUntilKey = false
                cl.busy = true
                cl.conn.send(content: msg, completion: .contentProcessed { [weak self] err in
                    self?.q.async {
                        cl.busy = false
                        if err != nil { self?.drop(id) }
                    }
                })
            }
            if needKey {
                self.cam.encoder.reportCongestion()
                self.cam.encoder.requestKeyframe()
            }
        }
    }

    private func broadcast(_ jpeg: Data, preview: Bool) {
        q.async {
            guard !self.clients.isEmpty else { return }
            var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            part.append(jpeg)
            part.append(Data("\r\n".utf8))
            for (id, cl) in self.clients where !cl.busy && cl.preview == preview {
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
