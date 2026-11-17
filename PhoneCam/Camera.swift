import AVFoundation
import CoreImage
import QuartzCore
import Vision

/// Owns the capture session. All device configuration runs on `queue`.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "cam.session")
    private let videoQueue = DispatchQueue(label: "cam.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let faces = AVCaptureMetadataOutput()
    private var followFace = true          // on `queue`
    private var lastFacePoint: CGPoint?
    private var lastFaceTime = 0.0
    private var faceSeen = 0.0             // CACurrentMediaTime of the last face
    private var skinWB = true              // on `queue`: white balance driven by face skin colour
    private var expLock = false            // on `queue`: exposure frozen at a 1/30 s shutter

    // Effects (switches on the page). Render flags are read on videoQueue under `lock`.
    private var fxBlur = false             // background blur (Vision person segmentation)
    private var blurStrength = 3.0         // 0.05…12; blur radius ≈ strength × 8 px at full resolution
    private var visionMs = 0.0
    private let visionQueue = DispatchQueue(label: "cam.vision", qos: .userInitiated)
    private var visionBusy = false         // under `lock`
    private var lastMask: CIImage?         // under `lock`: latest person mask, sensor orientation, own memory
    private var lastMaskTime = 0.0
    private lazy var segRequest: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    // Face rectangle shared with videoQueue (sensor-normalized, top-left origin).
    private var faceRect: CGRect?
    private var faceRectTime = 0.0
    private var skinMeasureFrame = 0
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice? { input?.device }
    private let ci = CIContext(options: [.cacheIntermediates: false])

    // Settings, touched only on `queue`.
    private var lens = "wide"
    private var res = "1080"
    private var fps = 30

    // Render settings, read on videoQueue, written on queue.
    private let lock = NSLock()
    private var rotation = 0
    private var quality = 0.85
    private var saturation = 1.55   // 0…2
    private var contrast = 1.0     // 0.5…1.5
    private var black = 0.0        // -0.1 (lift) … +0.1 (crush)
    private var framing = true     // auto-frame: crop follows the face
    private var softZoom = 1.4     // crop factor while framing
    private var window = CGRect(x: 0, y: 0, width: 1, height: 1) // last crop, sensor-normalized

    // Auto-frame smoothing, videoQueue only.
    private var frameCenter = CGPoint(x: 0.5, y: 0.5)
    private var framingMoving = false

    var onFrame: ((Data) -> Void)?
    var wantsFrames: () -> Bool = { false }

    private var frameCount = 0
    private var fpsStart = CACurrentMediaTime()
    private(set) var measuredFps = 0.0
    private var encMs = 0.0   // render + JPEG time per frame (moving average)
    private var pipeMs = 0.0  // sensor capture → JPEG ready (moving average)

    // MARK: start

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.queue.async {
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.session.beginConfiguration()
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                if self.session.canAddOutput(self.faces) {
                    self.session.addOutput(self.faces)
                    self.faces.setMetadataObjectsDelegate(self, queue: self.queue)
                }
                self.session.commitConfiguration()
                self.switchLens("wide")
                var saved = Camera.saved() // last lens / resolution / rotation / quality …
                let exp = saved.removeValue(forKey: "exp")
                self.apply(saved)
                self.lockExposureLater(exp)
                self.session.startRunning()
                self.restoreZoom() // startRunning resets the zoom factor
            }
        }
    }

    // MARK: devices

    static let lensNames = ["ultra", "wide", "tele", "front"]

    private func findDevice(_ name: String) -> AVCaptureDevice? {
        switch name {
        case "ultra": return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case "tele": return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case "front": return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        default: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    private func preset(_ r: String) -> AVCaptureSession.Preset {
        switch r {
        case "720": return .hd1280x720
        case "4k": return .hd4K3840x2160
        default: return .hd1920x1080
        }
    }

    private func switchLens(_ name: String) {
        guard let d = findDevice(name), let inp = try? AVCaptureDeviceInput(device: d) else { return }
        session.beginConfiguration()
        let old = input
        if let old { session.removeInput(old) }
        if session.canAddInput(inp) {
            session.addInput(inp)
            input = inp
            lens = name
        } else if let old {
            session.addInput(old)
        }
        if !session.canSetSessionPreset(preset(res)) { res = "1080" }
        session.sessionPreset = preset(res)
        if let c = output.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } // less latency
            if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 } // native sensor orientation = focus-point coordinates
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
        if faces.availableMetadataObjectTypes.contains(.face) { faces.metadataObjectTypes = [.face] }
        session.commitConfiguration()
        applyFps()
        restoreZoom()
    }

    private func restoreZoom() {
        let z = Double(Camera.saved()["zoom"] ?? "") ?? 1
        if lock.withLock({ framing }) {
            // Framing crops in software from the full field of view; keep the optics wide.
            lock.withLock { softZoom = min(3, max(1.15, z)) }
            withDevice { d in d.videoZoomFactor = d.minAvailableVideoZoomFactor }
        } else {
            withDevice { d in d.videoZoomFactor = min(maxZoom(d), max(d.minAvailableVideoZoomFactor, CGFloat(z))) }
        }
    }

    private func applyFps() {
        guard let d = device else { return }
        let ok = d.activeFormat.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) - 0.5 }
        if !ok { fps = 30 }
        withDevice { d in
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        }
    }

    private func withDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        body(d)
    }

    // MARK: settings API (call on `queue`)

    private static let persisted = ["lens", "res", "fps", "rot", "q", "face", "sat", "con", "black", "zoom", "wb", "exp", "frame", "blur", "blurAmt"]

    static func saved() -> [String: String] {
        var p = (UserDefaults.standard.dictionary(forKey: "settings") as? [String: String]) ?? [:]
        if p["rot"] == nil { p["rot"] = "180" } // phone on a Mac mount: sensor image is upside down
        if p["face"] == nil { p["face"] = "1" }
        if p["wb"] == nil { p["wb"] = "skin" }
        if p["frame"] == nil { p["frame"] = "1" }
        if p["res"] == nil { p["res"] = "4k" } // auto-frame crops from 4K and scales down: sharp
        if p["q"] == nil { p["q"] = "0.85" } // half the size of 0.95, no visible difference
        if p["exp"] == nil || p["exp"] == "manual" { p["exp"] = "lock" }
        // Default grade: richer colour, contrast and blacks untouched.
        if p["sat"] == nil { p["sat"] = "1.55" }
        if p["con"] == nil { p["con"] = "1" }
        if p["black"] == nil { p["black"] = "0" }
        return p
    }

    func apply(_ p: [String: String]) {
        let keep = p.filter { Camera.persisted.contains($0.key) }
        if !keep.isEmpty {
            UserDefaults.standard.set(Camera.saved().merging(keep) { $1 }, forKey: "settings")
        }
        if let v = p["lens"], v != lens {
            switchLens(v) // a new lens starts in auto exposure
            if p["exp"] == nil { lockExposureLater(Camera.saved()["exp"]) }
        }
        if let v = p["res"], v != res, session.canSetSessionPreset(preset(v)) {
            session.beginConfiguration()
            session.sessionPreset = preset(v)
            session.commitConfiguration()
            res = v
            applyFps()
            restoreZoom()
        }
        if let v = p["fps"], let f = Int(v), f == 30 || f == 60 { fps = f; applyFps() }
        if let v = p["rot"], let r = Int(v), [0, 90, 180, 270].contains(r) { lock.withLock { rotation = r } }
        if let v = p["q"], let q = Double(v) { lock.withLock { quality = min(0.98, max(0.3, q)) } }
        if let v = p["sat"], let x = Double(v) { lock.withLock { saturation = min(2, max(0, x)) } }
        if let v = p["con"], let x = Double(v) { lock.withLock { contrast = min(1.5, max(0.5, x)) } }
        if let v = p["black"], let x = Double(v) { lock.withLock { black = min(0.1, max(-0.1, x)) } }

        if let v = p["face"] {
            followFace = v == "1"
            lastFacePoint = nil
            if followFace { withDevice { d in
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            } }
        }
        // Manual focus / point focus turns face following off.
        if p["tap"] != nil || p["lensPos"] != nil || p["focus"] == "lock" {
            followFace = false
            var saved = Camera.saved(); saved["face"] = "0"
            UserDefaults.standard.set(saved, forKey: "settings")
        }
        if let v = p["tap"] {
            let parts = v.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { tap(u: parts[0], v: parts[1]) }
        }
        if let v = p["focus"] {
            withDevice { d in
                if v == "lock", d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                if v == "auto", d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            }
        }
        if let v = p["lensPos"], let f = Float(v) {
            withDevice { d in
                if d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(lensPosition: min(1, max(0, f)), completionHandler: nil)
                }
            }
        }

        if let v = p["exp"] {
            expLock = v == "lock"
            withDevice { d in
                switch v {
                case "lock":
                    // Freeze the current brightness with the slowest shutter the frame rate allows
                    // (1/30 s at 30 fps): same exposure, lower ISO, less noise.
                    if d.isExposureModeSupported(.custom) {
                        let f = d.activeFormat
                        let target = maxShutter(d)
                        let iso = Float(Double(d.iso) * d.exposureDuration.seconds / target)
                        d.setExposureModeCustom(duration: clampDuration(d, CMTime(seconds: target, preferredTimescale: 1_000_000)),
                                                iso: min(f.maxISO, max(f.minISO, iso)), completionHandler: nil)
                    } else if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                case "manual":
                    if d.isExposureModeSupported(.custom) {
                        d.setExposureModeCustom(duration: clampDuration(d, d.exposureDuration), iso: d.iso, completionHandler: nil)
                    }
                default: if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                }
            }
        }
        if let v = p["ev"], let f = Float(v) {
            withDevice { d in d.setExposureTargetBias(min(d.maxExposureTargetBias, max(d.minExposureTargetBias, f)), completionHandler: nil) }
        }
        if p["iso"] != nil || p["shutter"] != nil {
            expLock = false
            withDevice { d in
                guard d.isExposureModeSupported(.custom) else { return }
                let f = d.activeFormat
                var iso = d.iso
                if let v = p["iso"], let i = Float(v) { iso = min(f.maxISO, max(f.minISO, i)) }
                var dur = d.exposureDuration
                if let v = p["shutter"], let s = Double(v) { dur = CMTime(seconds: s, preferredTimescale: 1_000_000) }
                d.setExposureModeCustom(duration: clampDuration(d, dur), iso: iso, completionHandler: nil)
            }
        }

        if let v = p["wb"] {
            skinWB = v == "skin"
            withDevice { d in
                if v == "lock", d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
                if v == "auto", d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
        }
        if p["temp"] != nil { skinWB = false }
        if let v = p["temp"], let t = Float(v) {
            withDevice { d in
                guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
                var g = d.deviceWhiteBalanceGains(for: .init(temperature: t, tint: 0))
                let m = d.maxWhiteBalanceGain
                g.redGain = min(m, max(1, g.redGain))
                g.greenGain = min(m, max(1, g.greenGain))
                g.blueGain = min(m, max(1, g.blueGain))
                d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            }
        }

        if let v = p["blur"] { lock.withLock { fxBlur = v == "1" } }
        if let v = p["blurAmt"], let x = Double(v) { lock.withLock { blurStrength = min(12, max(0.05, x)) } }
        if let v = p["frame"] {
            lock.withLock { framing = v == "1" }
            if p["zoom"] == nil { restoreZoom() }
        }
        if let v = p["zoom"], let z = Double(v) {
            if lock.withLock({ framing }) {
                lock.withLock { softZoom = min(3, max(1.15, z)) }
            } else {
                withDevice { d in
                    d.videoZoomFactor = min(maxZoom(d), max(d.minAvailableVideoZoomFactor, CGFloat(z)))
                }
            }
        }
    }

    /// Picture coordinates (as shown, after rotation) → unrotated sensor coordinates.
    static func toSensor(u: Double, v: Double, rotation r: Int) -> CGPoint {
        switch r {
        case 90: return CGPoint(x: v, y: 1 - u)
        case 180: return CGPoint(x: 1 - u, y: 1 - v)
        case 270: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    /// Exposure "lock" needs a settled auto exposure first: lock a few seconds after start / lens switch.
    private func lockExposureLater(_ exp: String?) {
        guard exp == "lock" else { return }
        queue.asyncAfter(deadline: .now() + 3) {
            if Camera.saved()["exp"] == "lock" { self.apply(["exp": "lock"]) }
        }
    }

    private func maxZoom(_ d: AVCaptureDevice) -> CGFloat { min(d.maxAvailableVideoZoomFactor, 10) }

    private func maxShutter(_ d: AVCaptureDevice) -> Double {
        min(d.activeFormat.maxExposureDuration.seconds, 1.0 / Double(fps))
    }

    private func clampDuration(_ d: AVCaptureDevice, _ t: CMTime) -> CMTime {
        let s = min(maxShutter(d), max(d.activeFormat.minExposureDuration.seconds, t.seconds.isFinite ? t.seconds : 1.0 / 60))
        return CMTime(seconds: s, preferredTimescale: 1_000_000)
    }

    /// (u, v) are 0…1 on the picture as shown (after rotation); map back to sensor coordinates.
    private func tap(u: Double, v: Double) {
        let (r, on, win) = lock.withLock { (rotation, framing, window) }
        let w = Camera.toSensor(u: u, v: v, rotation: r)
        let p = on ? CGPoint(x: win.minX + w.x * win.width, y: win.minY + w.y * win.height) : w
        let relock = expLock
        if relock {
            withDevice { d in
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
            queue.asyncAfter(deadline: .now() + 1.5) { if self.expLock { self.apply(["exp": "lock"]) } }
        }
        withDevice { d in
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = p
                if d.focusMode == .locked, d.isFocusModeSupported(.autoFocus) {
                    d.focusMode = .autoFocus // focus once on the point, then hold
                } else if d.isFocusModeSupported(.continuousAutoFocus) {
                    d.focusMode = .continuousAutoFocus
                }
            }
            if d.isExposurePointOfInterestSupported, d.exposureMode != .custom {
                d.exposurePointOfInterest = p
                if d.exposureMode == .locked, d.isExposureModeSupported(.autoExpose) {
                    d.exposureMode = .autoExpose
                } else if d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    func state() -> [String: Any] {
        guard let d = device else { return ["ok": false] }
        let f = d.activeFormat
        let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        let (rot, q, sat, con, blk) = lock.withLock { (rotation, quality, saturation, contrast, black) }
        func n(_ x: Double) -> Double { x.isFinite ? x : 0 }
        let focus: String
        switch d.focusMode {
        case .locked: focus = "lock"
        case .continuousAutoFocus: focus = "auto"
        default: focus = "once"
        }
        let exp: String
        switch d.exposureMode {
        case .custom: exp = expLock ? "lock" : "manual"
        case .locked: exp = "lock"
        default: exp = "auto"
        }
        return [
            "ok": true,
            "lens": lens,
            "lenses": Camera.lensNames.filter { findDevice($0) != nil },
            "res": res,
            "fps": fps,
            "realFps": n((measuredFps * 10).rounded() / 10),
            "encMs": n((encMs * 10).rounded() / 10), "pipeMs": n((pipeMs * 10).rounded() / 10),
            "rot": rot,
            "q": q, "sat": sat, "con": con, "black": blk,
            "focus": followFace ? "face" : focus,
            "faceSeen": CACurrentMediaTime() - faceSeen < 1,
            "focusSupported": d.isLockingFocusWithCustomLensPositionSupported,
            "lensPos": n(Double(d.lensPosition)),
            "exp": exp,
            "iso": n(Double(d.iso)), "isoMin": n(Double(f.minISO)), "isoMax": n(Double(f.maxISO)),
            "shutter": n(d.exposureDuration.seconds),
            "shutterMin": n(f.minExposureDuration.seconds), "shutterMax": n(maxShutter(d)),
            "ev": n(Double(d.exposureTargetBias)),
            "evMin": n(Double(d.minExposureTargetBias)), "evMax": n(Double(d.maxExposureTargetBias)),
            "wb": skinWB ? "skin" : (d.whiteBalanceMode == .locked ? "lock" : "auto"),
            "temp": n(Double(tt.temperature)),
            "frame": lock.withLock { framing } ? "1" : "0",
            "blur": lock.withLock { fxBlur } ? "1" : "0",
            "blurAmt": lock.withLock { blurStrength },
            "visionMs": n((visionMs * 10).rounded() / 10),
            "zoom": lock.withLock { framing } ? lock.withLock { softZoom } : n(Double(d.videoZoomFactor)),
            "zoomMin": lock.withLock { framing } ? 1.15 : n(Double(d.minAvailableVideoZoomFactor)),
            "zoomMax": lock.withLock { framing } ? 3.0 : n(Double(maxZoom(d))),
        ]
    }

    // MARK: face following

    /// Runs on `queue`. Metadata face bounds use the same normalized sensor
    /// coordinates as focus/exposure points of interest.
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let found = objects.compactMap { $0 as? AVMetadataFaceObject }
        guard let face = found.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return }
        let now = CACurrentMediaTime()
        faceSeen = now
        lock.withLock { faceRect = face.bounds; faceRectTime = now }
        guard followFace else { return }
        let c = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
        if let last = lastFacePoint, hypot(c.x - last.x, c.y - last.y) < 0.04, now - lastFaceTime < 2 { return }
        guard now - lastFaceTime > 0.4 else { return }
        lastFacePoint = c
        lastFaceTime = now
        withDevice { d in
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = c
                d.focusMode = .continuousAutoFocus
            }
            if d.isExposurePointOfInterestSupported, d.exposureMode != .custom, d.exposureMode != .locked {
                d.exposurePointOfInterest = c
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    // MARK: skin-tone white balance

    // Target skin colour (sRGB 0…255), a neutral medium-light tone.
    private static let skinTarget = (r: 222.0, g: 172.0, b: 146.0)
    private static func lin(_ c: Double) -> Double {
        let x = c / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// videoQueue: average colour of the centre of the face, a few times a second.
    private func measureSkin(_ pb: CVPixelBuffer) {
        skinMeasureFrame += 1
        guard skinMeasureFrame % 8 == 0 else { return }
        let (rect, t) = lock.withLock { (faceRect, faceRectTime) }
        guard let rect, CACurrentMediaTime() - t < 1 else { return }
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        // Middle 40% of the face box: nose and cheeks, away from hair, hat and background.
        let inner = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
        let r = CGRect(x: inner.minX * w, y: (1 - inner.maxY) * h, width: inner.width * w, height: inner.height * h)
        guard r.width > 4, r.height > 4 else { return }
        let img = CIImage(cvPixelBuffer: pb)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [Float](repeating: 0, count: 4)
        ci.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                  format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        let (R, G, B) = (Double(px[0]), Double(px[1]), Double(px[2]))
        guard G > 0.003 else { return } // too dark to judge
        queue.async { self.correctWhiteBalance(rg: R / G, bg: B / G) }
    }

    /// queue: nudge the camera's white-balance gains so the face reaches the target ratios.
    private func correctWhiteBalance(rg: Double, bg: Double) {
        guard skinWB else { return }
        let t = Camera.skinTarget
        let tg = Camera.lin(t.g)
        let er = (Camera.lin(t.r) / tg) / rg
        let eb = (Camera.lin(t.b) / tg) / bg
        guard abs(log(er)) > 0.03 || abs(log(eb)) > 0.03 else { return } // close enough: hold steady
        withDevice { d in
            guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var g = d.deviceWhiteBalanceGains
            let step = 0.35 // move part of the way each time: smooth, no flicker
            var r = Double(g.redGain) * pow(er, step)
            var gr = Double(g.greenGain)
            var b = Double(g.blueGain) * pow(eb, step)
            let lo = min(r, gr, b) // gains must stay >= 1
            r /= lo; gr /= lo; b /= lo
            let m = Double(d.maxWhiteBalanceGain)
            g.redGain = Float(min(m, r)); g.greenGain = Float(min(m, gr)); g.blueGain = Float(min(m, b))
            d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
        }
    }

    // MARK: auto-frame

    /// videoQueue: crop window (sensor-normalized, top-left origin) that keeps the face
    /// horizontally centred with the eyes a bit above the middle. Moves like a camera operator:
    /// starts only after a clear offset, eases in, stops when close.
    private func framingWindow(rotation: Int, zoom: Double) -> CGRect {
        let size = 1 / zoom
        let (rect, t) = lock.withLock { (faceRect, faceRectTime) }
        var goal = frameCenter
        if let rect, CACurrentMediaTime() - t < 1.5 {
            // Where the face centre should sit inside the window, in sensor orientation.
            let spot = Camera.toSensor(u: 0.5, v: 0.45, rotation: rotation)
            goal = CGPoint(x: rect.midX - size * (spot.x - 0.5), y: rect.midY - size * (spot.y - 0.5))
        }
        let half = size / 2
        goal.x = min(1 - half, max(half, goal.x))
        goal.y = min(1 - half, max(half, goal.y))
        frameCenter.x = min(1 - half, max(half, frameCenter.x)) // zoom may have changed
        frameCenter.y = min(1 - half, max(half, frameCenter.y))
        let dist = hypot(goal.x - frameCenter.x, goal.y - frameCenter.y)
        if dist > size * 0.15 { framingMoving = true }   // ignore small moves
        if dist < size * 0.03 { framingMoving = false }
        if framingMoving {
            let k = 0.02 // per frame: ~3 s to settle at 30 fps
            frameCenter.x += (goal.x - frameCenter.x) * k
            frameCenter.y += (goal.y - frameCenter.y) * k
        }
        return CGRect(x: frameCenter.x - half, y: frameCenter.y - half, width: size, height: size)
    }

    /// Scale so the long side is 1920 and both sides are whole even pixels (1920×1080 for 16:9).
    private static func fit(_ img: CIImage) -> CIImage {
        let e = img.extent
        let long = max(e.width, e.height)
        let outW = (e.width / long * 1920 / 2).rounded() * 2
        let outH = (e.height / long * 1920 / 2).rounded() * 2
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: outW / e.width, y: outH / e.height)))
            .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    }

    // MARK: background blur

    /// videoQueue: start a person-segmentation pass on its own queue if none is running.
    /// Frames never wait for Vision; they use the latest finished mask.
    private func requestMask(_ pb: CVPixelBuffer, rotation: Int) {
        let busy = lock.withLock { () -> Bool in
            if visionBusy { return true }
            visionBusy = true
            return false
        }
        guard !busy else { return }
        visionQueue.async {
            defer { self.lock.withLock { self.visionBusy = false } }
            let t0 = CACurrentMediaTime()
            let orient: CGImagePropertyOrientation
            switch rotation {
            case 90: orient = .right
            case 180: orient = .down
            case 270: orient = .left
            default: orient = .up
            }
            // Vision wants the person upright; the mask comes back upright too.
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orient)
            try? handler.perform([self.segRequest])
            guard let m = self.segRequest.results?.first?.pixelBuffer else { return }
            var mask = CIImage(cvPixelBuffer: m)
            switch orient { // back to sensor orientation
            case .right: mask = mask.oriented(.left)
            case .left: mask = mask.oriented(.right)
            case .down: mask = mask.oriented(.down)
            default: break
            }
            // Copy out of Vision's buffer, which it reuses on the next pass.
            guard let cg = self.ci.createCGImage(mask, from: mask.extent) else { return }
            let own = CIImage(cgImage: cg)
            self.visionMs = self.visionMs * 0.9 + (CACurrentMediaTime() - t0) * 1000 * 0.1
            self.lock.withLock { self.lastMask = own; self.lastMaskTime = CACurrentMediaTime() }
        }
    }

    /// videoQueue: latest mask scaled to the frame, edge softened.
    private func currentMask(size: CGSize) -> CIImage? {
        guard var mask = lock.withLock({ CACurrentMediaTime() - lastMaskTime < 1 ? lastMask : nil }) else { return nil }
        let e = mask.extent
        mask = mask.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height)))
        // Soften the edge a little so hair does not look cut out.
        return mask.clampedToExtent().applyingGaussianBlur(sigma: size.width / 400).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            measuredFps = Double(frameCount) / (now - fpsStart)
            frameCount = 0
            fpsStart = now
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        measureSkin(pb)
        guard wantsFrames() else { return }
        let (rot, q, sat, con, blk) = lock.withLock { (rotation, quality, saturation, contrast, black) }
        var img = CIImage(cvPixelBuffer: pb)
        let (blurOn, blurSigma) = lock.withLock { (fxBlur, blurStrength) }
        if blurOn { requestMask(pb, rotation: rot) }
        if blurOn, let mask = currentMask(size: img.extent.size) {
            // Blur a smaller copy (cheap) and scale it back up. Strong blur uses 1/8 size; light blur
            // uses a larger copy, down to full size, so the downscale itself adds no softness.
            let e = img.extent
            let sigmaFull = blurSigma * 8
            var s = 1.0
            while s > 0.125 && sigmaFull * s > 4 { s /= 2 }
            let bg = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                .clampedToExtent().applyingGaussianBlur(sigma: sigmaFull * s)
                .transformed(by: CGAffineTransform(scaleX: 1 / s, y: 1 / s)).cropped(to: e)
            img = img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask])
        }
        let (on, zoom) = lock.withLock { (framing, softZoom) }
        if on {
            let W = img.extent.width, H = img.extent.height
            let win = framingWindow(rotation: rot, zoom: zoom)
            lock.withLock { window = win }
            let r = CGRect(x: win.minX * W, y: (1 - win.maxY) * H, width: win.width * W, height: win.height * H).integral
            img = Camera.fit(img.cropped(to: r)) // output 1920×1080 whatever the capture size
        } else if max(img.extent.width, img.extent.height) > 1920 {
            img = Camera.fit(img) // 4K capture → 1080p stream
        }
        let grade = sat != 1 || con != 1 || blk != 0
        // Grade in gamma-encoded sRGB, like a photo editor, not in CoreImage's linear space.
        if grade { img = img.applyingFilter("CILinearToSRGBToneCurve") }
        if sat != 1 || con != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: sat, kCIInputContrastKey: con, kCIInputBrightnessKey: 0])
        }
        if blk != 0 {
            // Levels: crush (blk > 0) maps blk→0; lift (blk < 0) maps 0→-blk.
            let scale = blk > 0 ? 1 / (1 - blk) : 1 + blk
            let bias = blk > 0 ? -blk / (1 - blk) : -blk
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        if grade { img = img.applyingFilter("CISRGBToneCurveToLinear") }
        switch rot {
        case 90: img = img.oriented(.right)
        case 180: img = img.oriented(.down)
        case 270: img = img.oriented(.left)
        default: break
        }
        let t0 = CACurrentMediaTime()
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ci.jpegRepresentation(
                of: img, colorSpace: cs,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): q])
        else { return }
        let t1 = CACurrentMediaTime()
        encMs = encMs * 0.9 + (t1 - t0) * 1000 * 0.1
        let captured = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if captured.isFinite, hostNow > captured { pipeMs = pipeMs * 0.9 + (hostNow - captured) * 1000 * 0.1 }
        onFrame?(data)
    }
}
