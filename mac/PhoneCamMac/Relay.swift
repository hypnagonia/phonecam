import Foundation
import Network

/// localhost:4747 → PhoneCam on the iPhone (USB link first, then Wi‑Fi).
/// The camera extension and the browser talk to localhost; only this app needs Local Network access.
final class Relay: ObservableObject {
    static let port: UInt16 = 4747
    @Published var listening = false
    @Published var portBusy = false
    @Published var phone: String?        // last address that answered
    @Published var connections = 0

    private let q = DispatchQueue(label: "relay")
    private var listener: NWListener?
    private var active = 0

    func start() {
        q.async { self.listen() }
        // Look for the phone now and then, so the menu shows where it is.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.probe() }
        probe()
    }

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
    private var listener6: NWListener?

    private func makeListener(host: NWEndpoint.Host) -> NWListener? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: Relay.port)!)
        params.allowLocalEndpointReuse = true
        let l = try? NWListener(using: params)
        l?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return l
    }

    /// Port taken (e.g. the Python relay is running): fine, the camera still gets its video. Retry later.
    private func fail() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.listening = false; self.portBusy = true }
        q.asyncAfter(deadline: .now() + 5) { self.listen() }
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: q)
        connectPhone(candidates()) { [weak self] phone in
            guard let self else { return }
            guard let phone else {
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
            self.pipe(from: client, to: phone, close: close)
            self.pipe(from: phone, to: client, close: close)
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

    /// Try addresses in order; the first that connects within 2 s wins.
    private func connectPhone(_ ips: [String], done: @escaping (NWConnection?) -> Void) {
        guard let ip = ips.first else { return done(nil) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        let c = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: Relay.port)!,
                             using: NWParameters(tls: nil, tcp: tcp))
        var finished = false
        c.stateUpdateHandler = { [weak self] s in
            guard !finished else { return }
            switch s {
            case .ready:
                finished = true
                DispatchQueue.main.async { self?.phone = ip }
                done(c)
            case .failed, .cancelled, .waiting:
                finished = true
                c.cancel()
                self?.connectPhone(Array(ips.dropFirst()), done: done)
            default: break
            }
        }
        c.start(queue: q)
    }

    private func probe() {
        q.async {
            self.connectPhone(self.candidates()) { c in
                c?.cancel()
                if c == nil { DispatchQueue.main.async { self.phone = nil } }
            }
        }
    }

    /// The iPhone's addresses from the ARP table (USB link-local 169.254.x.x first), plus an optional
    /// host name set with `defaults write <bundle id> host My-iPhone.local`.
    private func candidates() -> [String] {
        var ips: [String] = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-a"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            for line in text.split(separator: "\n") where line.lowercased().contains("iphone") {
                if let a = line.firstIndex(of: "("), let b = line.firstIndex(of: ")"), a < b {
                    ips.append(String(line[line.index(after: a)..<b]))
                }
            }
        }
        ips.sort { $0.hasPrefix("169.254.") && !$1.hasPrefix("169.254.") }
        if let host = UserDefaults.standard.string(forKey: "host") { ips.append(host) }
        var seen = Set<String>()
        return ips.filter { seen.insert($0).inserted }
    }
}
