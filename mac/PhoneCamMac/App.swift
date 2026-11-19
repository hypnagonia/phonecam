import AppKit
import ServiceManagement
import SwiftUI
import SystemExtensions

@main
struct PhoneCamMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var relay = AppDelegate.relay
    @ObservedObject private var installer = AppDelegate.installer

    var body: some Scene {
        MenuBarExtra {
            MenuView(relay: AppDelegate.relay, installer: AppDelegate.installer)
        } label: {
            Image(nsImage: PhoneIcon.image(status.color))
                .accessibilityLabel(status.label)
        }
        .menuBarExtraStyle(.window)
    }

    /// green: the phone is there and the camera runs; grey: no phone, or stopped from the menu;
    /// red: iOS stopped the iPhone camera, or the camera extension waits for approval
    private var status: CamStatus {
        if !relay.interrupted.isEmpty || installer.needsApproval { return .error }
        return relay.phone != nil && !relay.paused ? .on : .off
    }
}

enum CamStatus {
    case off, on, error
    var color: NSColor { self == .on ? .systemGreen : self == .error ? .systemRed : .secondaryLabelColor }
    var label: String { self == .on ? "PhoneCam: on" : self == .error ? "PhoneCam: needs attention" : "PhoneCam: off" }
}

/// The menu bar icon: a phone with its camera lens cut out, filled, coloured by CamStatus.
enum PhoneIcon {
    static func image(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            color.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 1, width: 9, height: 16), xRadius: 2.4, yRadius: 2.4)
            body.append(NSBezierPath(ovalIn: NSRect(x: 9 - 2.6, y: 11.2 - 2.6, width: 5.2, height: 5.2)))  // the lens
            body.windingRule = .evenOdd
            body.fill()
            NSBezierPath(ovalIn: NSRect(x: 9 - 1.1, y: 11.2 - 1.1, width: 2.2, height: 2.2)).fill()       // its centre
            return true
        }
        img.isTemplate = false
        return img
    }
}



/// Starts the relay and installs the camera at launch (the menu bar label never runs `.task`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let relay = Relay()
    static let installer = Installer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.relay.start()
        AppDelegate.installer.activate() // installs or updates the camera; no-op when current
    }
}

struct MenuView: View {
    @ObservedObject var relay: Relay
    @ObservedObject var installer: Installer
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(relay.phone == nil ? Color.red : Color.green).frame(width: 8, height: 8)
                Text(relay.phone.map { "iPhone at \($0)" } ?? "iPhone not found").font(.headline)
            }
            Text(relay.paused ? "Camera stopped" : "Camera stream: \(relay.cameraTransport)").font(.caption).foregroundStyle(.secondary)
            if !relay.interrupted.isEmpty {
                Text("iPhone camera stopped: \(relay.interrupted)").font(.caption).foregroundStyle(.orange)
            }
            Text(relay.listening ? "Relay on localhost:\(Relay.port) · \(relay.connections) open"
                 : relay.portBusy ? "Port \(Relay.port) is used by another relay (that is fine)"
                 : "Starting relay…")
                .font(.caption).foregroundStyle(.secondary)

            Button(relay.paused ? "Start camera" : "Stop camera") { relay.setPaused(!relay.paused) }
                .help("Stopped: apps see \"no signal\" and the iPhone camera sleeps (cooler, saves battery)")
            if !relay.presets.isEmpty {
                Menu("Presets") {
                    ForEach(relay.presets, id: \.self) { name in Button(name) { relay.loadPreset(name) } }
                }
                .fixedSize()
            }

            Divider()
            Text("Camera: \(installer.status)").font(.callout)
            if installer.needsApproval {
                Button("Open Camera Extensions settings") { installer.openSettings() }
            }
            HStack {
                Button("Reinstall camera") { installer.activate() }
                Button("Remove camera") { installer.deactivate() }
            }

            Divider()
            Button("Open control page") { NSWorkspace.shared.open(URL(string: "http://localhost:\(Relay.port)")!) }
            Toggle("Start at login", isOn: $atLogin)
                .onChange(of: atLogin) { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { relay.refreshPresets() }
        // A window-style menu may stay alive between openings: refresh every time it opens.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in relay.refreshPresets() }
    }
}

/// Installs the camera system extension embedded in this app.
final class Installer: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "checking…"
    @Published var needsApproval = false
    // macOS starts an updated camera extension only after a reboot when an older build with the same
    // name was loaded; a new name avoids that (".camera" → ".cam" → ".vcam"). Keep the extension stable.
    private var id: String { Bundle.main.bundleIdentifier! + ".vcam" }

    func activate() {
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: id, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func deactivate() {
        let r = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: id, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
        status = "removing…"
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        needsApproval = true
        status = "allow it in System Settings → General → Login Items & Extensions → Camera Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        needsApproval = false
        status = result == .completed ? "installed — pick “PhoneCam” in your call app" : "restart the Mac to finish"
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "error: \(error.localizedDescription)"
    }
}
