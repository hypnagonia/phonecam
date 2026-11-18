import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion

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

    // Face rectangle shared with videoQueue (sensor-normalized, top-left origin).
    private var faceRect: CGRect?
    private var faceRectTime = 0.0
    private var trackPoint: CGPoint?       // under `lock`: where auto-frame aims (sensor-normalized)
    private var trackTime = 0.0
    private var skinMeasureFrame = 0
    private var skinSeen = 0.0
    private var faceHueDeg: Double?        // on `queue`: smoothed hue of the face (sRGB HSV degrees)
    private var skinShift = 0.0            // on `queue`: hue rotation applied to skin tones, degrees
    private var builtShift = 0.0           // on `queue`: skinShift the current cube was built with
    private var skinWarm = 0.0             // on `queue`: -1 pinker … +1 more golden skin (±12° of hue)
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice? { input?.device }
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var bitDepth = 8               // on `queue`: 10 when a 10-bit SDR format is in use

    /// ±0.75 of an 8-bit step, the same for R, G and B (luma only, no colour speckle), fixed in place so the
    /// encoder sees it as unchanging texture. Added just before 8-bit output to break gradients' steps.
    private let dither: CIImage = {
        let a = 1.5 / 255
        return CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -a / 2, y: -a / 2, z: -a / 2, w: 0),
        ])
    }()

    // Settings, touched only on `queue`.
    private var lens = "wide"
    private var fps = 30

    // Render settings, read on videoQueue, written on queue.
    private let lock = NSLock()
    private var rotation = 0
    private var quality = 0.95
    private var saturation = 1.2   // 0…2
    private var contrast = 1.0     // 0.5…1.5
    private var black = 0.0        // -0.1 (lift) … +0.1 (crush)
    private var hueSat = (red: 1.0, green: 1.0, blue: 0.6) // extra saturation per hue band (0…1.5)
    private var hueCube: Data?     // 32³ colour cube for hueSat, rebuilt when it changes
    private var framing = true     // auto-frame: crop follows the face
    private var level = true       // auto-level: rotate the picture so the horizon is straight
    private var tilt = 0.0         // under `lock`: smoothed roll of the phone, radians (0 = level)
    private var autoRot = true     // under `lock`: rotation follows how the phone is mounted
    private var gravityDeg = 0.0   // under `lock`: angle of gravity in the phone's x-y plane (diagnostics)
    private var rotCandidate = -1, rotStable = 0 // motion queue: a new orientation must hold ~1 s
    private let motion = CMMotionManager()
    private var softZoom = 1.4     // crop factor while framing
    private var window = CGRect(x: 0, y: 0, width: 1, height: 1) // last crop, sensor-normalized

    // Auto-frame smoothing, videoQueue only.
    private var frameCenter = CGPoint(x: 0.5, y: 0.5)
    private var framingMoving = false

    var onFrame: ((Data, Bool) -> Void)?          // JPEG for /video: full (OBS Browser Source) or preview
    var wantsJPEG: () -> Bool = { false }
    var wantsPreview: () -> Bool = { false }
    var wantsHEVC: () -> Bool = { false }
    private(set) lazy var encoder = HEVCEncoder(ci: ci) // /hevc for the Mac camera

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
                self.startMotion()
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
        // Always 4K: auto-frame and the upright crop cut 1080p out of it, so they stay sharp.
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        use10Bit(d)
        if let c = output.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } // less latency
            if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 } // native sensor orientation = focus-point coordinates
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
        // Faces, plus whole bodies as a fallback for auto-frame when the face is turned away or hidden.
        faces.metadataObjectTypes = [.face, .humanBody].filter { faces.availableMetadataObjectTypes.contains($0) }
        session.commitConfiguration()
        applyFps()
        restoreZoom()
    }

    /// 10-bit capture in plain sRGB (not HDR) when the camera offers it at 4K: the grading then works on
    /// smooth gradients instead of 8-bit steps. On iPhone the 10-bit 4:2:0 formats are HDR-only (HLG), but the
    /// 10-bit 4:2:2 ones (made for ProRes) also do sRGB. Falls back to the preset's 8-bit format.
    private func use10Bit(_ d: AVCaptureDevice) {
        func maxFps(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        for tenBit in [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange] {
            // The slowest format that still reaches the frame rate (fast modes may bin pixels).
            guard let fmt = d.formats.filter({ f in
                let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return dim.width == 3840 && dim.height == 2160
                    && CMFormatDescriptionGetMediaSubType(f.formatDescription) == tenBit
                    && f.supportedColorSpaces.contains(.sRGB) && maxFps(f) >= Double(fps) - 0.1
            }).min(by: { maxFps($0) < maxFps($1) }) else { continue }
            // The output lists the 10-bit pixel formats only once the camera is in a 10-bit mode.
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            session.sessionPreset = .inputPriority
            guard (try? d.lockForConfiguration()) != nil else { continue }
            d.activeFormat = fmt
            d.activeColorSpace = .sRGB
            d.unlockForConfiguration()
            if output.availableVideoPixelFormatTypes.contains(tenBit) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: tenBit]
                bitDepth = 10
                return
            }
        }
        // No 10-bit SDR mode: back to the 8-bit 4K preset.
        bitDepth = 8
        output.videoSettings = nil
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
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

    private static let persisted = ["lens", "fps", "rot", "q", "face", "sat", "con", "black", "red", "green", "blue", "skinWarm", "zoom", "wb", "exp", "frame", "level"]

    static func saved() -> [String: String] {
        var p = (UserDefaults.standard.dictionary(forKey: "settings") as? [String: String]) ?? [:]
        if p["rot"] == nil { p["rot"] = "auto" } // picked from gravity (a Mac mount gives 180)
        if p["face"] == nil { p["face"] = "1" }
        if p["wb"] == nil { p["wb"] = "skin" }
        if p["frame"] == nil { p["frame"] = "1" }
        if p["level"] == nil { p["level"] = "1" }
        if p["q"] == nil { p["q"] = "0.95" } // maximum JPEG quality (USB carries it easily)
        if p["exp"] == nil || p["exp"] == "manual" { p["exp"] = "lock" }
        // Default grade: richer colour, contrast and blacks untouched.
        if p["sat"] == nil { p["sat"] = "1.2" }
        if p["con"] == nil { p["con"] = "1" }
        if p["black"] == nil { p["black"] = "0" }
        if p["red"] == nil { p["red"] = "1" }
        if p["green"] == nil { p["green"] = "1" }
        if p["blue"] == nil { p["blue"] = "0.6" } // tame the blue room behind a warm-lit face
        if p["lens"] == nil { p["lens"] = "wide" }
        if p["fps"] == nil { p["fps"] = "30" }
        if p["zoom"] == nil { p["zoom"] = "1.4" }
        if p["skinWarm"] == nil { p["skinWarm"] = "0" }
        return p
    }

    func apply(_ p: [String: String]) {
        if p["reset"] == "1" { return resetToDefaults() }
        let keep = p.filter { Camera.persisted.contains($0.key) }
        if !keep.isEmpty {
            UserDefaults.standard.set(Camera.saved().merging(keep) { $1 }, forKey: "settings")
        }
        if let v = p["lens"], v != lens {
            switchLens(v) // a new lens starts in auto exposure
            if p["exp"] == nil { lockExposureLater(Camera.saved()["exp"]) }
        }
        if let v = p["fps"], let f = Int(v), f == 30 || f == 60, f != fps {
            fps = f
            switchLens(lens) // the 10-bit format for this frame rate
        }
        if let v = p["rot"] {
            if v == "auto" { lock.withLock { autoRot = true } }
            else if let r = Int(v), [0, 90, 180, 270].contains(r) { lock.withLock { autoRot = false; rotation = r } }
        }
        if let v = p["q"], let q = Double(v) {
            let qq = min(0.98, max(0.3, q))
            lock.withLock { quality = qq }
            encoder.setBitrate(Camera.bitrate(quality: qq))
        }
        if let v = p["sat"], let x = Double(v) { lock.withLock { saturation = min(2, max(0, x)) } }
        if let v = p["con"], let x = Double(v) { lock.withLock { contrast = min(1.5, max(0.5, x)) } }
        if let v = p["black"], let x = Double(v) { lock.withLock { black = min(0.1, max(-0.1, x)) } }
        if let v = p["skinWarm"], let x = Double(v) { skinWarm = min(1, max(-1, x)) }
        if p["red"] != nil || p["green"] != nil || p["blue"] != nil || p["sat"] != nil {
            var h = lock.withLock { hueSat }
            func val(_ k: String, _ old: Double) -> Double { Double(p[k] ?? "").map { min(1.5, max(0, $0)) } ?? old }
            h = (red: val("red", h.red), green: val("green", h.green), blue: val("blue", h.blue))
            lock.withLock { hueSat = h }
            rebuildCube()
        }

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
            skinShift = 0; faceHueDeg = nil
            rebuildCube()
            withDevice { d in
                if v == "lock", d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
                if v == "auto" || v == "skin", d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        }
        if p["temp"] != nil { skinWB = false; skinShift = 0; rebuildCube() }
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

        if let v = p["level"] { lock.withLock { level = v == "1" } }
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

    /// Sensor coordinates → picture coordinates as shown (inverse of `toSensor`).
    static func toDisplay(_ p: CGPoint, rotation r: Int) -> CGPoint {
        switch r {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
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

    /// Gravity → roll of the phone around the camera axis, relative to the nearest upright orientation.
    /// About 10 updates a second, smoothed; nothing when the phone lies flat.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] m, _ in
            guard let self, let g = m?.gravity, abs(g.z) < 0.9 else { return }
            let phi = atan2(g.y, g.x)
            let quarter = Double.pi / 2
            let dev = phi - (phi / quarter).rounded() * quarter // deviation from the nearest 90°
            let d = min(.pi / 12, max(-.pi / 12, dev))          // leveling: at most ±15°
            // Orientation: the sensor image is upright when gravity points along -x (phi 180°), so the
            // picture needs rotating by phi + 180° (rounded to 90°). Switch only when the phone is clearly
            // in the new position (within 30°) for ~1 s.
            let phiDeg = phi * 180 / .pi
            var cand = Int(((phiDeg + 180) / 90).rounded()) * 90 % 360
            if cand < 0 { cand += 360 }
            if abs(dev) < .pi / 6 {
                if cand == self.rotCandidate { self.rotStable += 1 } else { self.rotCandidate = cand; self.rotStable = 0 }
            }
            let settle = self.rotStable >= 10
            self.lock.withLock {
                self.tilt += (d - self.tilt) * 0.2
                self.gravityDeg = phiDeg
                if self.autoRot, settle, self.rotation != cand { self.rotation = cand }
            }
        }
    }

    /// Forget every saved setting and apply the defaults from `saved()`. Exposure runs in auto for a
    /// few seconds and then locks, as at launch.
    private func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: "settings")
        var d = Camera.saved()
        let exp = d.removeValue(forKey: "exp")
        d["ev"] = "0"
        apply(d)
        expLock = false
        withDevice { dev in
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        }
        lockExposureLater(exp)
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
        let cropped = on || r == 90 || r == 270 // the picture is a crop of the sensor
        let p = cropped ? CGPoint(x: win.minX + w.x * win.width, y: win.minY + w.y * win.height) : w
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
            "fps": fps,
            "realFps": n((measuredFps * 10).rounded() / 10),
            "bitDepth": bitDepth,
            "encMs": n((encMs * 10).rounded() / 10), "pipeMs": n((pipeMs * 10).rounded() / 10),
            "rot": lock.withLock { autoRot } ? "auto" : "\(rot)",
            "rotNow": rot,
            "gravity": n((lock.withLock { gravityDeg } * 10).rounded() / 10),
            "q": q, "sat": sat, "con": con, "black": blk, "red": lock.withLock { hueSat.red }, "green": lock.withLock { hueSat.green },
            "blue": lock.withLock { hueSat.blue },
            "skinWarm": skinWarm,
            "faceHue": n(((faceHueDeg ?? 0) * 10).rounded() / 10), "skinShift": n((skinShift * 10).rounded() / 10),
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
            "level": lock.withLock { level } ? "1" : "0",
            "tilt": n((lock.withLock { tilt } * 180 / .pi * 100).rounded() / 100),
            "zoom": lock.withLock { framing } ? lock.withLock { softZoom } : n(Double(d.videoZoomFactor)),
            "zoomMin": lock.withLock { framing } ? 1.15 : n(Double(d.minAvailableVideoZoomFactor)),
            "zoomMax": lock.withLock { framing } ? 3.0 : n(Double(maxZoom(d))),
        ]
    }

    // MARK: face following

    /// Runs on `queue`. Metadata face bounds use the same normalized sensor
    /// coordinates as focus/exposure points of interest.
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        let area = { (o: AVMetadataObject) in o.bounds.width * o.bounds.height }
        let found = objects.compactMap { $0 as? AVMetadataFaceObject }
        guard let face = found.max(by: { area($0) < area($1) }) else {
            // No face: aim auto-frame at the head of the largest body (its top part, as shown on screen).
            if let body = objects.filter({ $0.type == .humanBody }).max(by: { area($0) < area($1) }) {
                let r = lock.withLock { rotation }
                let b = body.bounds
                let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)].map { Camera.toDisplay($0, rotation: r) }
                let top = min(corners[0].y, corners[1].y), height = abs(corners[0].y - corners[1].y)
                let head = Camera.toSensor(u: (corners[0].x + corners[1].x) / 2, v: top + height * 0.15, rotation: r)
                lock.withLock { trackPoint = head; trackTime = now }
            }
            return
        }
        faceSeen = now
        lock.withLock {
            faceRect = face.bounds; faceRectTime = now
            trackPoint = CGPoint(x: face.bounds.midX, y: face.bounds.midY); trackTime = now
        }
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
        // Bright light can push the red channel of skin to its limit; then the face reads "not red
        // enough" and the loop would add red. Skip such samples.
        guard max(R, G, B) < 0.85 else { return }
        queue.async { self.correctSkinHue(r: R, g: G, b: B) }
    }

    /// queue: Skin mode. Auto white balance stays on for the whole scene; the face is fixed by rotating
    /// the hue of skin tones only (a narrow band around the face's own hue) toward natural skin. Saturation
    /// and brightness stay as they are, and the rest of the picture (background, clothes) is untouched.
    private func correctSkinHue(r: Double, g: Double, b: Double) {
        guard let h = Camera.hueDegrees(linear: (r, g, b)) else { return }
        let now = CACurrentMediaTime()
        if now - skinSeen > 1.5 { faceHueDeg = nil }
        skinSeen = now
        // Smooth over ~1 s so a hand, a shadow or a short flash on the face does not swing the colour.
        faceHueDeg = faceHueDeg.map { $0 + Camera.angle(h - $0) * 0.3 } ?? h
        guard skinWB, let fh = faceHueDeg else { return }
        let target = Camera.skinHueDeg + 12 * skinWarm
        let want = min(20, max(-20, Camera.angle(target - fh)))
        skinShift += (want - skinShift) * 0.25
        if abs(skinShift - builtShift) > 0.5 { rebuildCube() }
    }

    /// Target skin hue (sRGB HSV degrees). Natural-looking skin sits near 20°; reddish skin measures lower
    /// (around 14° in daylight with auto white balance), so turning it toward 20° makes it look more natural.
    private static let skinHueDeg = 20.0

    /// Signed difference of two hue angles, -180…180.
    static func angle(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    /// HSV hue in degrees (0…360) of an RGB colour; nil when max − min ≤ `minChroma` (near-grey).
    static func hue(_ r: Double, _ g: Double, _ b: Double, minChroma: Double = 0.0001) -> Double? {
        let mx = max(r, g, b), d = mx - min(r, g, b)
        guard d > minChroma else { return nil }
        var h: Double
        if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
        return h < 0 ? h + 360 : h
    }

    /// Hue of a linear RGB colour after sRGB encoding (as the picture shows it).
    static func hueDegrees(linear c: (Double, Double, Double)) -> Double? {
        func enc(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        return hue(enc(c.0), enc(c.1), enc(c.2), minChroma: 0.02)
    }

    /// queue: rebuild the colour cube from the hue sliders, saturation and the current skin correction.
    private func rebuildCube() {
        let (h, sat) = lock.withLock { (hueSat, saturation) }
        let center = faceHueDeg ?? Camera.skinHueDeg
        let shift = skinWB ? skinShift : 0
        builtShift = shift
        let neutral = [h.red, h.green, h.blue, sat].allSatisfy { abs($0 - 1) < 0.01 } && abs(shift) < 0.25
        let cube = neutral ? nil : Camera.hueCube(h, saturation: sat, skinCenter: center, skinShift: shift)
        lock.withLock { hueCube = cube }
    }

    /// 32³ RGBA colour cube (sRGB in → sRGB out) that scales saturation per hue band: red ~15° (incl. skin
    /// and orange), green ~120°, blue/cyan ~210°. Each band fades out over ±60°; neutral greys never change.
    static func hueCube(_ k: (red: Double, green: Double, blue: Double), saturation: Double,
                        skinCenter: Double = 14, skinShift: Double = 0) -> Data {
        let protect = 1 / max(0.3, saturation) // undo the global saturation on skin tones
        func band30(_ h: Double, _ center: Double) -> Double {
            var d = abs(h - center).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d >= 30 ? 0 : 0.5 + 0.5 * cos(.pi * d / 30)
        }
        func band(_ h: Double, _ center: Double) -> Double {
            var d = abs(h - center).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d >= 60 ? 0 : 0.5 + 0.5 * cos(.pi * d / 60)
        }
        let n = 32
        var out = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
                    var (rr, gg, bb) = (r, g, b)
                    if let h = hue(r, g, b) {
                        var f = 1 + (k.red - 1) * band(h, 15) + (k.green - 1) * band(h, 120) + (k.blue - 1) * band(h, 210)
                        // Skin tones (~25°, narrower band) keep their natural saturation.
                        let sk = band30(h, 25)
                        f *= 1 + (protect - 1) * sk
                        if abs(f - 1) > 0.0001 {
                            // Scale chroma around the grey of the same luminance, so brightness stays.
                            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                            rr = y + (r - y) * f; gg = y + (g - y) * f; bb = y + (b - y) * f
                        }
                    }
                    if abs(skinShift) > 0.25 {
                        // Rotate the hue of skin tones (±30° around the face's hue) by skinShift, keeping
                        // HSV saturation and value, so only the shade of the skin changes.
                        let x = (min(1, max(0, rr)), min(1, max(0, gg)), min(1, max(0, bb)))
                        let mx = max(x.0, x.1, x.2), d = mx - min(x.0, x.1, x.2)
                        if let h = hue(x.0, x.1, x.2) {
                            let w = band30(h, skinCenter)
                            if w > 0 {
                                var nh = (h + skinShift * w).truncatingRemainder(dividingBy: 360)
                                if nh < 0 { nh += 360 }
                                let sv = d / mx, v = mx
                                let c = v * sv, hp = nh / 60, xx = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
                                var t: (Double, Double, Double)
                                switch Int(hp) {
                                case 0: t = (c, xx, 0)
                                case 1: t = (xx, c, 0)
                                case 2: t = (0, c, xx)
                                case 3: t = (0, xx, c)
                                case 4: t = (xx, 0, c)
                                default: t = (c, 0, xx)
                                }
                                let m = v - c
                                rr = t.0 + m; gg = t.1 + m; bb = t.2 + m
                            }
                        }
                    }
                    out[i] = Float(min(1, max(0, rr))); out[i + 1] = Float(min(1, max(0, gg)))
                    out[i + 2] = Float(min(1, max(0, bb))); out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: auto-frame

    /// videoQueue: crop window (sensor-normalized, top-left origin) that keeps the face
    /// horizontally centred with the eyes a bit above the middle. Moves like a camera operator:
    /// starts only after a clear offset, eases in, stops when close.
    /// Crop size (sensor-normalized) for a 16:9 landscape picture: the whole sensor when the picture is
    /// landscape (rotation 0/180); a landscape band across the tall frame when the phone is upright (90/270).
    static func windowSize(rotation: Int, zoom: Double, sensorAspect a: Double) -> (w: Double, h: Double) {
        // a = sensor height / width. Largest 16:9 (as shown) inside the sensor, then zoomed.
        let r = 16.0 / 9
        if rotation == 90 || rotation == 270 {
            // Shown width = sensor height, shown height = sensor width.
            return (w: min(1, a / r) / zoom, h: min(1, r / a) / zoom)
        }
        return (w: min(1, r * a) / zoom, h: min(1, 1 / (r * a)) / zoom)
    }

    private func framingWindow(rotation: Int, zoom: Double, sensorAspect: Double) -> CGRect {
        let ws = Camera.windowSize(rotation: rotation, zoom: zoom, sensorAspect: sensorAspect)
        let (pt, t) = lock.withLock { (trackPoint, trackTime) }
        var goal = frameCenter
        if let pt, CACurrentMediaTime() - t < 2 {
            // Where the face centre should sit inside the window, in sensor orientation.
            let spot = Camera.toSensor(u: 0.5, v: 0.45, rotation: rotation)
            goal = CGPoint(x: pt.x - ws.w * (spot.x - 0.5), y: pt.y - ws.h * (spot.y - 0.5))
        }
        let hw = ws.w / 2, hh = ws.h / 2
        goal.x = min(1 - hw, max(hw, goal.x))
        goal.y = min(1 - hh, max(hh, goal.y))
        frameCenter.x = min(1 - hw, max(hw, frameCenter.x)) // zoom or orientation may have changed
        frameCenter.y = min(1 - hh, max(hh, frameCenter.y))
        let size = max(ws.w, ws.h)
        let dist = hypot(goal.x - frameCenter.x, goal.y - frameCenter.y)
        if dist > size * 0.10 { framingMoving = true }   // ignore small moves
        if dist < size * 0.02 { framingMoving = false }
        if framingMoving {
            let k = 0.03 // per frame: ~2 s to settle at 30 fps
            frameCenter.x += (goal.x - frameCenter.x) * k
            frameCenter.y += (goal.y - frameCenter.y) * k
        }
        return CGRect(x: frameCenter.x - hw, y: frameCenter.y - hh, width: ws.w, height: ws.h)
    }

    /// Rotate around the centre and zoom just enough that no empty corners show; same size out.
    static func leveled(_ img: CIImage, angle a: Double) -> CIImage {
        let e = img.extent
        let w = e.width, h = e.height, c = abs(cos(a)), s = abs(sin(a))
        let zoom = max((w * c + h * s) / w, (w * s + h * c) / h)
        let t = CGAffineTransform(translationX: e.midX, y: e.midY)
            .rotated(by: a)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -e.midX, y: -e.midY)
        return img.transformed(by: t).cropped(to: e)
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
        let wantJ = wantsJPEG(), wantH = wantsHEVC(), wantP = wantsPreview()
        guard wantJ || wantH || wantP else { return }
        let (rot, q, sat, con, blk) = lock.withLock { (rotation, quality, saturation, contrast, black) }
        var img = CIImage(cvPixelBuffer: pb)
        let (on, zoom) = lock.withLock { (framing, softZoom) }
        let W = img.extent.width, H = img.extent.height
        let upright = rot == 90 || rot == 270
        if on || upright || abs(Double(W / H) - 16.0 / 9) > 0.01 {
            // Auto-frame, or a phone standing upright: crop a 16:9 landscape window (centred when not framing).
            let win: CGRect
            if on {
                win = framingWindow(rotation: rot, zoom: zoom, sensorAspect: Double(H / W))
            } else {
                let ws = Camera.windowSize(rotation: rot, zoom: 1, sensorAspect: Double(H / W))
                win = CGRect(x: 0.5 - ws.w / 2, y: 0.5 - ws.h / 2, width: ws.w, height: ws.h)
            }
            lock.withLock { window = win }
            let r = CGRect(x: win.minX * W, y: (1 - win.maxY) * H, width: win.width * W, height: win.height * H).integral
            img = Camera.fit(img.cropped(to: r)) // output 1920×1080 whatever the capture size
        } else if max(img.extent.width, img.extent.height) > 1920 {
            img = Camera.fit(img) // 4K capture → 1080p stream
        }
        let cube = lock.withLock { hueCube }
        let grade = sat != 1 || con != 1 || blk != 0 || cube != nil
        // Grade in gamma-encoded sRGB, like a photo editor, not in CoreImage's linear space.
        if grade { img = img.applyingFilter("CILinearToSRGBToneCurve") }
        if sat != 1 || con != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: sat, kCIInputContrastKey: con, kCIInputBrightnessKey: 0])
        }
        if let cube {
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 32, "inputCubeData": cube])
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
        // Rolling the phone by +β about its z axis makes gravity read -β; the rear camera (looking along -z)
        // then sees the scene turned clockwise, so the picture is turned back by +β: angle = -tilt.
        let (lv, tl) = lock.withLock { (level, tilt) }
        if lv, abs(tl) > 0.002 { img = Camera.leveled(img, angle: -tl) }
        // Dither before the 8-bit output, in sRGB (where the 8-bit steps are), so smooth gradients like a lit
        // wall don't break into bands.
        img = img.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: dither.cropped(to: img.extent)])
            .cropped(to: img.extent)
            .applyingFilter("CISRGBToneCurveToLinear")
        // Exactly 1920×1080 at the origin for the encoder (720p capture is scaled up, 4K already scaled down).
        let e = img.extent
        if e.width != CGFloat(HEVCEncoder.width) || e.height != CGFloat(HEVCEncoder.height) { img = Camera.fit(img) }
        else if e.minX != 0 || e.minY != 0 { img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)) }
        let t0 = CACurrentMediaTime()
        // The picture is rendered once: by the HEVC encoder when the camera is in use; the JPEGs are then
        // made from that finished frame instead of running the whole chain (crop, colour, level) again.
        if wantH, let done = encoder.encode(img, pts: CMSampleBufferGetPresentationTimeStamp(sb)) {
            img = CIImage(cvPixelBuffer: done)
        }
        if wantJ, let data = jpeg(img, quality: q) { onFrame?(data, false) }
        if wantP, let data = jpeg(img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.0 / 3]), quality: 0.5) {
            onFrame?(data, true) // control-page preview: 640×360, light enough not to crowd the camera's Wi‑Fi
        }
        let t1 = CACurrentMediaTime()
        encMs = encMs * 0.9 + (t1 - t0) * 1000 * 0.1
        let captured = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if captured.isFinite, hostNow > captured { pipeMs = pipeMs * 0.9 + (hostNow - captured) * 1000 * 0.1 }
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func jpeg(_ img: CIImage, quality: Double) -> Data? {
        ci.jpegRepresentation(of: img, colorSpace: srgb,
                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }

    /// Quality slider (0.4…0.95) → HEVC bitrate, 4…24 Mbit/s.
    static func bitrate(quality q: Double) -> Int {
        let t: Double = (min(0.95, max(0.4, q)) - 0.4) / 0.55
        let mbps: Double = 4 + t * 20
        return Int(mbps * 1_000_000)
    }
}
