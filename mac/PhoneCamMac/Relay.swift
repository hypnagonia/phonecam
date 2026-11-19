import Foundation
import Network
import QuartzCore
import PhoneCamCore

/// localhost:4747 → PhoneCam on the iPhone. The camera extension and the browser talk to localhost; only this
/// app needs Local Network access. Every relayed request gets the shared key (Local.xcconfig → Info.plist),
/// which the phone requires, so nothing else on the network can reach the camera.
///
/// Routes: the USB cable, or direct Wi‑Fi between iPhone and Mac (AWDL, like AirDrop). Never through the
/// router: the Mac's own Wi‑Fi network interface is prohibited for every connection to the phone, so Bonjour
/// can only resolve over the cable or peer-to-peer. The working route is remembered; new connections reuse
/// it and only fall back to a full search when it stops answering. A probe every 5 s switches to a better
/// route (e.g. the cable was plugged in).
final class Relay: ObservableObject {
    static let port: UInt16 = 4747
    @Published var listening = false
    @Published var portBusy = false
    @Published var phone: String?        // how the phone is reached, for the menu
    @Published var connections = 0
    @Published var cameraTransport = "–"  // how the camera stream arrives: UDP or TCP
    @Published private(set) var paused = false // camera stopped from the menu: apps get "no signal", the iPhone sleeps
    @Published private(set) var presets: [String] = [] // saved on the iPhone, for the menu
    @Published private(set) var interrupted = ""      // why iOS stopped the iPhone camera, for the menu

    private static let key: String = {
        let k = (Bundle.main.object(forInfoDictionaryKey: "PhoneCamKey") as? String) ?? ""
        return k.hasPrefix("$(") ? "" : k
    }()

    /// A way to reach the phone: an endpoint, optionally pinned to one interface (direct Wi‑Fi).
    struct Route { let endpoint: NWEndpoint; let via: NWInterface? }

    private let q = DispatchQueue(label: "relay")
    private var listener: NWListener?
    private var arpIPs: [String] = []      // on q: last ARP read
    private let arpQ = DispatchQueue(label: "arp", qos: .utility)
    private var listener6: NWListener?
    private var browser: NWBrowser?
    private let pathMonitor = NWPathMonitor()
    private var routerWiFi: NWInterface?   // on q: the Mac's infrastructure Wi‑Fi (to the router): never used
    private var bonjour: [NWEndpoint] = [] // on q: PhoneCam services seen on the network
    private var bonjourUDP: [NWEndpoint] = [] // on q: its UDP stream service
    private var udpBrowser: NWBrowser?
    private var best: Route?               // on q: the route that worked last
    private var active = 0                 // on q
    private var link = "none"              // on q: "usb", "wifi" (direct) or "none", for the control page
    private var transport = "–"            // on q: how the camera stream arrives
    private var stopped = false            // on q: mirror of `paused`

    // The camera stream for local viewers (the camera extension), received from the phone over UDP.
    private lazy var udp: UDPReceiver = {
        let r = UDPReceiver(queue: q, key: Relay.key)
        r.onFrame = { [weak self] msg, isKey in self?.fanOut(msg, isKey: isKey) }
        return r
    }()
    private final class Local {
        let conn: NWConnection
        let head: Data
        var headerSent = false
        // Frames handed to the connection and not yet taken by the network stack. A viewer is only "lagging"
        // when this grows (see fanOut), not whenever one send is still under way.
        var pending = 0
        var pendingBytes = 0
        var skipUntilKey = true
        let since = CACurrentMediaTime()
        init(_ c: NWConnection, head: Data) { conn = c; self.head = head }
    }
    private var locals: [ObjectIdentifier: Local] = [:] // on q
    private static let maxPending = 8, maxPendingBytes = 6_000_000
    private var maintenance: DispatchSourceTimer?

    /// Menu: stop or start the camera. Stopped, the camera stream is refused (apps show the "no signal"
    /// card) and the iPhone is told to put its camera to sleep at once.
    func setPaused(_ on: Bool) {
        paused = on
        q.async {
            self.stopped = on
            guard on else { return }
            for id in Array(self.locals.keys) { self.dropLocal(id) }
            self.udp.stop()
            self.transport = "–"
            DispatchQueue.main.async { self.cameraTransport = "–" }
        }
        if on { URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(Relay.port)/set?sleep=1")!).resume() }
    }

    /// Menu: the iPhone's presets (read from /state through this relay).
    func refreshPresets() {
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(Relay.port)/state")!) { [weak self] data, _, _ in
            guard let data, let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let list = st["presets"] as? [String] ?? []
            let why = st["interrupted"] as? String ?? ""
            DispatchQueue.main.async {
                if self?.presets != list { self?.presets = list }
                if self?.interrupted != why { self?.interrupted = why }
            }
        }.resume()
    }

    func loadPreset(_ name: String) {
        var c = URLComponents(string: "http://127.0.0.1:\(Relay.port)/set")!
        c.queryItems = [URLQueryItem(name: "presetLoad", value: name)]
        URLSession.shared.dataTask(with: c.url!).resume()
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.routerWiFi = path.availableInterfaces.first { $0.type == .wifi && !$0.name.hasPrefix("awdl") }
        }
        pathMonitor.start(queue: q)
        q.async {
            self.listen(); self.browse(); self.probe()
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 1, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.maintainUDP() }
            t.resume()
            self.maintenance = t
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.q.async { self?.probe() } }
        // Presets and the camera's state for the menu: read when the menu opens (MenuView.onAppear), and once
        // a minute for the stop reason; every 5 s woke the phone's network for a menu nobody had open.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshPresets() }
    }

    // MARK: listening on localhost

    private func listen() {
        guard let l = makeListener(host: "127.0.0.1") else { return fail() }
        l.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: DispatchQueue.main.async { self?.listening = true; self?.portBusy = false }
            case .failed: self?.fail()
            default: break
            }
        }
        l.start(queue: q)
        listener = l
        // Browsers may try IPv6 first for "localhost"; best effort, IPv4 is the one that matters.
        if listener6 == nil, let l6 = makeListener(host: "::1") {
            l6.stateUpdateHandler = { [weak self] s in if case .failed = s { self?.listener6 = nil } }
            l6.start(queue: q)
            listener6 = l6
        }
    }

    private func makeListener(host: NWEndpoint.Host) -> NWListener? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: Relay.port)!)
        params.allowLocalEndpointReuse = true
        let l = try? NWListener(using: params)
        l?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return l
    }

    /// Port taken by something else: retry later.
    private func fail() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.listening = false; self.portBusy = true }
        q.asyncAfter(deadline: .now() + 5) { self.listen() }
    }

    // MARK: relaying

    private func accept(_ client: NWConnection) {
        client.start(queue: q)
        readHead(client, Data()) { [weak self] head in
            guard let self, let head else { client.cancel(); return }
            switch RelayHTTP.route(head) {
            case .camera: self.serveCamera(client, head: head)
            case .link: self.replyLink(client)
            case .proxy: self.proxy(client, head: head)
            }
        }
    }

    /// The request head (up to the blank line), so the request can be routed and the key added.
    private func readHead(_ c: NWConnection, _ buffer: Data, done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, end, err in
            var buf = buffer
            if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil || buf.count > 32768 { done(buf) }
            else if end || err != nil { done(nil) }
            else { self?.readHead(c, buf, done: done) }
        }
    }

    /// Relay a request to the phone over TCP, with the key added after the request line.
    private func proxy(_ client: NWConnection, head: Data) {
        // The remembered route first; a full search only when it fails.
        let routes = (best.map { [$0] } ?? []) + candidates(withARP: best == nil)
        connectPhone(routes) { [weak self] result in
            guard let self else { return }
            guard let (phone, _) = result else {
                let body = "PhoneCam is not reachable: open the PhoneCam app on the iPhone."
                let resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                client.send(content: Data(resp.utf8), completion: .contentProcessed { _ in client.cancel() })
                return
            }
            self.active += 1
            self.publishCount()
            var closed = false
            let close = {
                guard !closed else { return }
                closed = true
                client.cancel()
                phone.cancel()
                self.active -= 1
                self.publishCount()
            }
            let out = RelayHTTP.addHeader(head, name: "X-PhoneCam-Key", value: Relay.key)
            phone.send(content: out, completion: .contentProcessed { e in
                if e != nil { close() } else { self.pipe(from: client, to: phone, close: close) }
            })
            self.pipe(from: phone, to: client, close: close)
        }
    }

    /// q: answered here, not by the phone: how the Mac reaches the phone (for the control page).
    private func replyLink(_ c: NWConnection) {
        let n = udp.counts
        let udpJSON = "{\"mode\":\"\(udp.mode)\",\"wakeups\":\(n.wakeups),\"packets\":\(n.packets),\"frames\":\(n.frames),\"keyRequests\":\(n.keyRequests),\"lossReports\":\(n.lossReports)}"
        let body = "{\"link\":\"\(link)\",\"camera\":\"\(locals.isEmpty ? "–" : transport)\",\"udp\":\(udpJSON)}"
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: camera stream over UDP

    /// q: a local viewer (the camera extension) wants /hevc. Feed it from the UDP receiver; if no frame
    /// comes within 2.5 s (UDP blocked?), fall back to relaying /hevc over TCP like any other request.
    private func serveCamera(_ client: NWConnection, head: Data) {
        if stopped {
            let resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            client.send(content: Data(resp.utf8), completion: .contentProcessed { _ in client.cancel() })
            return
        }
        let l = Local(client, head: head)
        let id = ObjectIdentifier(l)
        locals[id] = l
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, end, err in
            if end || err != nil { self?.dropLocal(id) }
        }
        if udp.started { udp.requestKey() } else { startUDP() }
        q.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, let l = self.locals[id], !l.headerSent else { return }
            self.locals[id] = nil
            self.transport = "TCP"
            DispatchQueue.main.async { self.cameraTransport = "TCP" }
            self.proxy(l.conn, head: l.head)
        }
    }

    private func dropLocal(_ id: ObjectIdentifier) {
        guard let l = locals.removeValue(forKey: id) else { return }
        l.conn.cancel()
    }

    /// q: subscribe over UDP: by Bonjour over direct Wi‑Fi first (brings up AWDL, no router), else by
    /// Bonjour any way, else to the host the TCP route reaches.
    private var udpStartedAt = 0.0
    private var udpAttempt = 0 // which way to try; moves on each time a way gives no frames for 3 s
    private func startUDP() {
        udpStartedAt = CACurrentMediaTime()
        let way = udpAttempt % 2
        udpAttempt += 1
        if way == 0, let ep = bonjourUDP.first { return udp.start(endpoint: ep, avoid: routerWiFi) }
        let routes = (best.map { [$0] } ?? []) + candidates(withARP: best == nil)
        connectPhone(routes) { [weak self] result in
            guard let self, let (c, _) = result else { return }
            let iface = c.currentPath?.availableInterfaces.first
            if case .hostPort(let h, _) = c.currentPath?.remoteEndpoint {
                self.udp.start(endpoint: .hostPort(host: h, port: 4747), via: iface, avoid: self.routerWiFi)
            }
            c.cancel()
        }
    }

    /// q: a complete frame from UDP → every local viewer that can take it.
    private func fanOut(_ msg: Data, isKey: Bool) {
        var needKey = false
        for (id, l) in locals {
            if l.skipUntilKey && !isKey { continue }
            // A viewer that really lags (more than a quarter of a second of frames, or 6 MB, queued) is cut
            // off until the next keyframe. One send still under way is not lagging: a keyframe is 0.5–1 MB and
            // does not leave within one frame's 33 ms. Dropping the next frame for that asked for another
            // keyframe, which again did not leave in time: the picture stood still for 6–7 s, whenever the
            // camera extension was a little late once (every 20–60 s on a busy Mac).
            if l.pending >= Relay.maxPending || l.pendingBytes > Relay.maxPendingBytes { l.skipUntilKey = true; needKey = true; continue }
            l.skipUntilKey = false
            l.pending += 1
            var out = msg
            if !l.headerSent {
                l.headerSent = true
                out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-phonecam-hevc\r\nConnection: close\r\n\r\n".utf8) + msg
                transport = "UDP"
                DispatchQueue.main.async { self.cameraTransport = "UDP" }
            }
            let size = out.count
            l.pendingBytes += size
            l.conn.send(content: out, completion: .contentProcessed { [weak self] e in
                self?.q.async {
                    l.pending -= 1
                    l.pendingBytes -= size
                    if e != nil { self?.dropLocal(id) }
                }
            })
        }
        if needKey { udp.requestKey() }
    }

    /// q: stop UDP when nobody watches; resubscribe when frames stop (the route may have changed).
    private func maintainUDP() {
        if locals.isEmpty {
            if udp.started && CACurrentMediaTime() - udp.lastFrameTime > 5 { udp.stop() }
            return
        }
        if udp.started && CACurrentMediaTime() - max(udp.lastFrameTime, udpStartedAt) > 3 {
            udp.stop()
            startUDP() // next way
        }
    }

    private func publishCount() {
        let n = active
        DispatchQueue.main.async { self.connections = n }
    }

    /// Copy a → b. When a ends, deliver what is left (and a FIN) before closing, otherwise the tail of
    /// a short response, like the page itself, is lost.
    private func pipe(from a: NWConnection, to b: NWConnection, close: @escaping () -> Void) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            let finished = done || err != nil
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { e in
                    if e != nil { return close() }
                    if finished {
                        b.send(content: nil, contentContext: .finalMessage, isComplete: true,
                               completion: .contentProcessed { _ in close() })
                    } else {
                        self?.pipe(from: a, to: b, close: close)
                    }
                })
            } else if finished {
                b.send(content: nil, contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { _ in close() })
            } else {
                self?.pipe(from: a, to: b, close: close)
            }
        }
    }

    // MARK: finding the phone

    /// The phone app announces "_phonecam._tcp"; keep the current list of where it is.
    private func browse() {
        let bp = NWParameters.tcp
        bp.includePeerToPeer = true // find the phone over direct Wi‑Fi too
        let b = NWBrowser(for: .bonjour(type: "_phonecam._tcp", domain: nil), using: bp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.bonjour = results.map(\.endpoint)
        }
        b.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.q.asyncAfter(deadline: .now() + 3) { self?.browse() } }
        }
        b.start(queue: q)
        browser = b
        let ub = NWBrowser(for: .bonjour(type: "_phonecam._udp", domain: nil), using: bp)
        ub.browseResultsChangedHandler = { [weak self] results, _ in self?.bonjourUDP = results.map(\.endpoint) }
        ub.start(queue: q)
        udpBrowser = ub
    }

    /// q: try routes in order; the first that connects within 2 s wins and becomes `best`.
    private func connectPhone(_ routes: [Route], done: @escaping ((NWConnection, Route)?) -> Void) {
        guard let route = routes.first else { return done(nil) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        noRouter(params)
        if let via = route.via { params.requiredInterface = via }
        let c = NWConnection(to: route.endpoint, using: params)
        var finished = false
        c.stateUpdateHandler = { [weak self] s in
            guard let self, !finished else { return }
            switch s {
            case .ready:
                finished = true
                self.best = route
                self.publishRoute(c, route)
                done((c, route))
            case .failed, .cancelled, .waiting:
                finished = true
                c.cancel()
                self.connectPhone(Array(routes.dropFirst()), done: done)
            default: break
            }
        }
        c.start(queue: q)
    }

    /// Cable or direct Wi‑Fi only: allow peer-to-peer, forbid the interface that leads to the router.
    private func noRouter(_ p: NWParameters) {
        p.includePeerToPeer = true
        if let r = routerWiFi { p.prohibitedInterfaces = [r] }
    }

    private func publishRoute(_ c: NWConnection, _ route: Route) {
        var host = "\(route.endpoint)"
        if case .hostPort(let h, _) = c.currentPath?.remoteEndpoint ?? route.endpoint { host = "\(h)" }
        let ifName = c.currentPath?.availableInterfaces.first?.name ?? ""
        let label = ifName.hasPrefix("awdl") ? "direct Wi‑Fi" : "USB cable (\(ifName))"
        link = ifName.hasPrefix("awdl") ? "wifi" : "usb"
        DispatchQueue.main.async { self.phone = label }
    }

    /// q: every 5 s look for the best route from scratch (the cable may have come back).
    private func probe() {
        refreshARP() // for the next probe; this one uses the last read
        connectPhone(candidates(withARP: true)) { [weak self] result in
            guard let self else { return }
            if let (c, _) = result { c.cancel(); return }
            self.best = nil
            self.link = "none"
            DispatchQueue.main.async { self.phone = nil }
        }
    }

    /// Routes in order of preference. The ARP table (USB link-local addresses) costs a process launch,
    /// so it is read by the background probe and on a full search, not for every relayed request.
    private func candidates(withARP: Bool) -> [Route] {
        let port = NWEndpoint.Port(rawValue: Relay.port)!
        var out = withARP ? arpCandidates().map { Route(endpoint: .hostPort(host: NWEndpoint.Host($0), port: port), via: nil) } : []
        out += bonjour.map { Route(endpoint: $0, via: nil) } // resolves over the cable or direct Wi‑Fi only
        return out
    }

    /// q: the iPhone's USB link-local addresses (169.254.x.x) from the last ARP read, plus an optional host
    /// name set with `defaults write <bundle id> host My-iPhone.local`. The table is read on `arpQ` and
    /// only the result comes back to `q`: `q` serves localhost:4747 and must never wait for a process.
    private func arpCandidates() -> [String] {
        var ips = arpIPs
        if let host = UserDefaults.standard.string(forKey: "host"), !ips.contains(host) { ips.append(host) }
        return ips
    }

    /// Read the ARP table in the background (`arp -an`: no reverse DNS, which took 5 s a call).
    private func refreshARP() {
        arpQ.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            p.arguments = ["-an"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let ips = ARP.linkLocal(String(decoding: data, as: UTF8.self))
            self?.q.async { self?.arpIPs = ips }
        }
    }
}
