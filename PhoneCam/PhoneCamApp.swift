import SwiftUI
import UIKit

@main
struct PhoneCamApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class Model: ObservableObject {
    static let shared = Model()
    let cam = Camera()
    lazy var server = Server(port: 4747, cam: cam)
    @Published var url = "…"
    @Published var status = ""
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        cam.start()
        server.start()
        refresh()
    }

    func refresh() {
        url = "http://\(Model.wifiAddress() ?? "no Wi‑Fi"):\(server.port)"
        status = "clients: \(server.clientCount) · \(Int(cam.measuredFps.rounded())) fps"
    }

    static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var result: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard a.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.ifa_name)
            guard name == "en0" || (result == nil && name.hasPrefix("bridge")) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a.ifa_addr, socklen_t(a.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result = String(cString: host)
            if name == "en0" { break }
        }
        return result
    }
}

struct ContentView: View {
    @StateObject private var m = Model.shared
    @State private var dim = false
    @State private var savedBrightness: CGFloat = 0.5
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("PhoneCam").font(.title2.bold())
                Text("Open on your Mac:").foregroundColor(.gray)
                Text(m.url)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .textSelection(.enabled)
                Text(m.status).font(.footnote.monospaced()).foregroundColor(.gray)
                Button(dim ? "Brighten" : "Dim screen") { toggleDim() }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                Text("Keep the app open: iOS stops the camera in the background.")
                    .font(.footnote).foregroundColor(.gray).multilineTextAlignment(.center)
            }
            .padding()
            .foregroundColor(.white)
            .opacity(dim ? 0.25 : 1)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            m.start()
        }
        .onReceive(tick) { _ in m.refresh() }
    }

    private func toggleDim() {
        dim.toggle()
        if dim {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
        } else {
            UIScreen.main.brightness = savedBrightness
        }
    }
}
