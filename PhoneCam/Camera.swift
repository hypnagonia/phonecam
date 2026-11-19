import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion
import PhoneCamCore

/// Owns the capture session. All device configuration runs on `queue`.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "cam.session")
    let videoQueue = DispatchQueue(label: "cam.video", qos: .userInteractive)
    let output = AVCaptureVideoDataOutput()
    let faces = AVCaptureMetadataOutput()
    var followFace = true          // on `queue`
    var lastFacePoint: CGPoint?
    var lastFaceTime = 0.0
    var faceSeen = 0.0             // CACurrentMediaTime of the last face
    var skinWB = true              // on `queue`: white balance driven by face skin colour
    var expLock = false            // on `queue`: exposure frozen at a 1/30 s shutter

    // Face rectangle shared with videoQueue (sensor-normalized, top-left origin).
    var faceRect: CGRect?
    var faceRectTime = 0.0
    var trackPoint: CGPoint?       // under `lock`: where auto-frame aims (sensor-normalized)
    var trackTime = 0.0
    var skinMeasureFrame = 0
    var userEV: Float = 0          // under `lock`: the EV slider
    var hlOffset: Float = 0        // videoQueue: highlight guard, added to the EV in auto exposure
    var faceLuma = (value: 0.0, time: 0.0) // videoQueue: brightness of the face centre (sRGB 0…1)
    var skinSeen = 0.0
    var faceHueDeg: Double?        // on `queue`: smoothed hue of the face (sRGB HSV degrees)
    var skinShift = 0.0            // on `queue`: hue rotation applied to skin tones, degrees
    var builtShift = 0.0           // on `queue`: skinShift the current cube was built with
    var skinWarm = 0.0             // on `queue`: -1 pinker … +1 more golden skin (±12° of hue)
    var input: AVCaptureDeviceInput?
    var device: AVCaptureDevice? { input?.device }
    let ci = CIContext(options: [.cacheIntermediates: false])
    var bitDepth = 8               // on `queue`: 10 when a 10-bit SDR format is in use

    /// ±0.75 of an 8-bit step, the same for R, G and B (luma only, no colour speckle), fixed in place so the
    /// encoder sees it as unchanging texture. Added just before 8-bit output to break gradients' steps.
    let dither: CIImage = {
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
    var lens = "wide"
    var fps = 30
    var cap = "4k"                 // capture size: "4k" (sharpest crops) or "1080" (cooler, less battery)
    // Heat: while the iPhone is hot, capture drops to 1080p at 30 fps; the chosen settings come back once it
    // has been cool for a minute. On `queue`.
    var heatLimited = false
    var coolSince: Double?
    var effCap: String { heatLimited ? "1080" : cap }
    // Low light at 60 fps: the shutter can't be longer than 1/60 s, so in a dark room auto exposure runs at 30
    // fps (1/30 s, half the ISO noise) until it is bright again. On `queue`.
    var darkLimited = false
    var darkSince: Double?, brightSince: Double?
    // Lamps on mains power flicker: "auto" (from the phone's region), "50" or "60" Hz. On `queue`.
    var mains = "auto"
    // Look: a built-in look or the user's .cube LUT ("" = none), and its strength. On `queue`.
    var lut = ""
    var lutAmt = 0.7
    var lutTable: (name: String, lut: CubeLUT)?
    var eyeCubeFor = -1.0                  // videoQueue
    var eyeCubeData: Data?                 // videoQueue
    var mainsHz: Int { mains == "50" ? 50 : mains == "60" ? 60 : Flicker.mainsHz(region: Locale.current.region?.identifier) }
    var effFps: Int { heatLimited || darkLimited ? 30 : fps }
    var capPreset: AVCaptureSession.Preset {
        effCap == "1080" || !session.canSetSessionPreset(.hd4K3840x2160) ? .hd1920x1080 : .hd4K3840x2160
    }

    // Render settings, read on videoQueue, written on queue.
    let lock = NSLock()
    var rotation = 0
    var quality = 0.95
    var saturation = 1.2   // 0…2
    var contrast = 1.0     // 0.5…1.5
    var black = 0.0        // -0.1 (lift) … +0.1 (crush)
    var warm = 0.0, tint = 0.0 // under `lock`: manual colour balance, -1…1 (warm: blue↔amber, tint: green↔magenta)
    var hsl = HSL()        // under `lock`: hue, saturation and luminance per colour
    // Auto accents (see Accents in PhoneCamCore): small colourful things in the background get richer.
    var accentsOn = false          // under `lock`
    var accentAmt = 0.6            // under `lock`: strength 0…1
    var autoSat = [Double](repeating: 0, count: 8) // under `lock`: the saturation the auto accents add now
    var accentTracker = Accents.Tracker() // videoQueue
    var accentFrame = 0                   // videoQueue
    var accentReset = false               // under `lock`: start the tracker afresh (turned on, scene reset)
    // Auto operator (see AutoOperator in PhoneCamCore).
    var steadyOn = true                   // on `queue`: hold auto exposure / white balance while the light is the same
    var expHold = AutoOperator.Hold(settle: 0.15, change: 0.6)   // on `queue`, EV
    var wbHold = AutoOperator.Hold(settle: 0.02, change: 0.08)   // on `queue`, relative gain change
    var wbRef: AVCaptureDevice.WhiteBalanceGains?                // on `queue`: gains last second / grey-world at hold
    var steadyExpHeld = false             // under `lock`
    var steadyWBHeld = false              // on `queue`
    var lightOn = true, lightAmt = 0.5    // under `lock`: face light and vignette
    var lightCenter = CGPoint(x: 0.5, y: 0.45), lightFace = 0.0, lightSize = 0.3 // videoQueue, smoothed
    var toneOn = true                     // under `lock`
    var autoTone = AutoOperator.Tone()    // under `lock`
    var toneTracker = AutoOperator.ToneTracker() // videoQueue
    var toneReset = false                 // under `lock`
    var hueCube: Data?     // 32³ colour cube for HSL, saturation and skin, rebuilt when they change
    var lutCube: (data: Data, size: Int)? // the look (LUT) mixed to its strength; nil = none
    var framing = true     // auto-frame: crop follows the face
    var level = true       // auto-level: rotate the picture so the horizon is straight
    var tilt = 0.0         // under `lock`: smoothed roll of the phone, radians (0 = level)
    var autoRot = true     // under `lock`: rotation follows how the phone is mounted
    var gravityDeg = 0.0   // under `lock`: angle of gravity in the phone's x-y plane (diagnostics)
    var rotCandidate = -1, rotStable = 0 // motion queue: a new orientation must hold ~1 s
    let motion = CMMotionManager()
    var softZoom = 1.15    // crop factor while framing
    var window = CGRect(x: 0, y: 0, width: 1, height: 1) // last crop, sensor-normalized

    // Auto-frame smoothing, videoQueue only.
    var frameCenter = CGPoint(x: 0.5, y: 0.5)
    var framingMoving = false

    var onFrame: ((Data, Bool) -> Void)?          // JPEG for /video: full (OBS Browser Source) or preview
    var wantsJPEG: () -> Bool = { false }
    var wantsPreview: () -> Bool = { false }
    var wantsHEVC: () -> Bool = { false }
    private(set) lazy var encoder = HEVCEncoder(ci: ci) // /hevc for the Mac camera

    var frameCount = 0
    var fpsStart = CACurrentMediaTime()
    var measuredFps = 0.0

    // Sleep: with nobody watching for 30 s the capture stops (no heat, no battery); it starts again within
    // about a second when a viewer appears. Settings can still be changed while asleep.
    static let sleepAfter = 30.0
    var lastViewer = CACurrentMediaTime() // on `queue`
    var idleTimer: DispatchSourceTimer?
    var asleep = false               // on `queue`
    var interrupted: String?         // on `queue`: why iOS stopped the camera (background, another app …); nil while it runs
    var restartAt = 0.0              // on `queue`: last start or restart of the session
    var lastFrameAt = 0.0            // under `lock`: time of the last frame from the sensor
    var sleepSoon = false                 // on `queue`: the Mac stopped the camera: sleep as soon as nobody watches
    var encMs = 0.0   // render + JPEG time per frame (moving average)
    var anaMs = 0.0   // skin colour and highlight measurements per frame (moving average)
    var previewTick = 0 // videoQueue: the control-page preview gets every other frame
    var pipeMs = 0.0  // sensor capture → JPEG ready (moving average)

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
                self.restartAt = CACurrentMediaTime()
                self.observeSession()
                self.startSleepTimer()
            }
        }
    }

    // MARK: devices

    static let lensNames = ["ultra", "wide", "tele", "front"]

    func findDevice(_ name: String) -> AVCaptureDevice? {
        switch name {
        case "ultra": return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case "tele": return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case "front": return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        default: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    func switchLens(_ name: String) {
        resetSteady() // a new camera starts in auto exposure and white balance
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
        session.sessionPreset = capPreset
        use10Bit(d)
        if let c = output.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off } // less latency
            if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 } // native sensor orientation = focus-point coordinates
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
        // Faces, plus whole bodies as a fallback for auto-frame when the face is turned away or hidden.
        faces.metadataObjectTypes = [.face, .humanBody].filter { faces.availableMetadataObjectTypes.contains($0) }
        session.commitConfiguration()
        withDevice { d in if d.isLowLightBoostSupported { d.automaticallyEnablesLowLightBoostWhenAvailable = true } }
        applyFps()
        restoreZoom()
    }

    /// 10-bit capture in plain sRGB (not HDR) when the camera offers it at 4K: the grading then works on
    /// smooth gradients instead of 8-bit steps. On iPhone the 10-bit 4:2:0 formats are HDR-only (HLG), but the
    /// 10-bit 4:2:2 ones (made for ProRes) also do sRGB. Falls back to the preset's 8-bit format.
    func use10Bit(_ d: AVCaptureDevice) {
        func maxFps(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        for tenBit in [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange] {
            // The slowest format that still reaches the frame rate (fast modes may bin pixels).
            guard let fmt = d.formats.filter({ f in
                let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let (w, h): (Int32, Int32) = effCap == "1080" ? (1920, 1080) : (3840, 2160)
                return dim.width == w && dim.height == h
                    && CMFormatDescriptionGetMediaSubType(f.formatDescription) == tenBit
                    && f.supportedColorSpaces.contains(.sRGB) && maxFps(f) >= Double(effFps) - 0.1
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
        session.sessionPreset = capPreset
    }

    func restoreZoom() {
        let z = Double(Camera.saved()["zoom"] ?? "") ?? 1
        if lock.withLock({ framing }) {
            // Framing crops in software from the full field of view; keep the optics wide.
            lock.withLock { softZoom = min(3, max(1.15, z)) }
            withDevice { d in d.videoZoomFactor = d.minAvailableVideoZoomFactor }
        } else {
            withDevice { d in d.videoZoomFactor = min(maxZoom(d), max(d.minAvailableVideoZoomFactor, CGFloat(z))) }
        }
    }

    func applyFps() {
        guard let d = device else { return }
        let ok = d.activeFormat.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(effFps) - 0.5 }
        if !ok { fps = 30 }
        let f = effFps
        withDevice { d in
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(f))
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(f))
        }
        encoder.setFrameRate(f)
    }

    func withDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        body(d)
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
        case .locked: exp = lock.withLock { steadyExpHeld } ? "auto" : "lock"
        default: exp = "auto"
        }
        return [
            "ok": true,
            "lens": lens,
            "lenses": Camera.lensNames.filter { findDevice($0) != nil },
            "fps": fps,
            "heatLimited": heatLimited, "darkLimited": darkLimited,
            "mains": mains, "mainsHz": mainsHz,
            "lut": lut, "lutAmt": lutAmt, "looks": Looks.names, "luts": Camera.userLUTs(),
            "presets": Presets.sortedNames(Camera.presets),
            "realFps": n((measuredFps * 10).rounded() / 10),
            "asleep": asleep,
            "interrupted": interrupted ?? "",
            "bitDepth": bitDepth,
            "cap": cap,
            "thermal": ["ok", "warm", "hot", "critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)],
            "encMs": n((encMs * 10).rounded() / 10), "anaMs": n((anaMs * 100).rounded() / 100), "pipeMs": n((pipeMs * 10).rounded() / 10),
            "rot": lock.withLock { autoRot } ? "auto" : "\(rot)",
            "rotNow": rot,
            "gravity": n((lock.withLock { gravityDeg } * 10).rounded() / 10),
            "q": q, "sat": sat, "con": con, "black": blk, "hsl": lock.withLock { hsl.string },
            "accents": lock.withLock { accentsOn } ? "1" : "0", "accentAmt": lock.withLock { accentAmt },
            "accentSat": lock.withLock { autoSat.map { ($0 * 100).rounded() / 100 } },
            "skinWarm": skinWarm, "warm": lock.withLock { warm }, "tint": lock.withLock { tint },
            "faceHue": n(((faceHueDeg ?? 0) * 10).rounded() / 10), "skinShift": n((skinShift * 10).rounded() / 10),
            "focus": followFace ? "face" : focus,
            "win": lock.withLock { [window.minX, window.minY, window.width, window.height].map { n((Double($0) * 1000).rounded() / 1000) } },
            "track": lock.withLock { trackPoint.map { [n((Double($0.x) * 1000).rounded() / 1000), n((Double($0.y) * 1000).rounded() / 1000), n(((CACurrentMediaTime() - trackTime) * 10).rounded() / 10)] } ?? [] },
            "faceSeen": CACurrentMediaTime() - faceSeen < 1,
            "focusSupported": d.isLockingFocusWithCustomLensPositionSupported,
            "lensPos": n(Double(d.lensPosition)),
            "exp": exp,
            "iso": n(Double(d.iso)), "isoMin": n(Double(f.minISO)), "isoMax": n(Double(f.maxISO)),
            "shutter": n(d.exposureDuration.seconds),
            "shutterMin": n(f.minExposureDuration.seconds), "shutterMax": n(maxShutter(d)),
            "ev": n(Double(lock.withLock { userEV })), "hlGuard": n((Double(hlOffset) * 10).rounded() / 10),
            "evMin": n(Double(d.minExposureTargetBias)), "evMax": n(Double(d.maxExposureTargetBias)),
            "wb": skinWB ? "skin" : (d.whiteBalanceMode == .locked && !steadyWBHeld ? "lock" : "auto"),
            "steady": steadyOn ? "1" : "0", "steadyExp": lock.withLock { steadyExpHeld }, "steadyWB": steadyWBHeld,
            "light": lock.withLock { lightOn } ? "1" : "0", "lightAmt": lock.withLock { lightAmt },
            "tone": lock.withLock { toneOn } ? "1" : "0", "toneNow": lock.withLock { [autoTone.contrast, autoTone.mids].map { ($0 * 100).rounded() / 100 } },
            "temp": n(Double(tt.temperature)),
            "frame": lock.withLock { framing } ? "1" : "0",
            "level": lock.withLock { level } ? "1" : "0",
            "tilt": n((lock.withLock { tilt } * 180 / .pi * 100).rounded() / 100),
            "zoom": lock.withLock { framing } ? lock.withLock { softZoom } : n(Double(d.videoZoomFactor)),
            "zoomMin": lock.withLock { framing } ? 1.15 : n(Double(d.minAvailableVideoZoomFactor)),
            "zoomMax": lock.withLock { framing } ? 3.0 : n(Double(maxZoom(d))),
        ]
    }


    // MARK: frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        let now = CACurrentMediaTime()
        lock.withLock { lastFrameAt = now }
        if now - fpsStart >= 1 {
            measuredFps = Double(frameCount) / (now - fpsStart)
            frameCount = 0
            fpsStart = now
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let a0 = CACurrentMediaTime()
        measureSkin(pb)
        guardHighlights(pb)
        analyzeAccents(pb)
        analyzeTone(pb)
        anaMs = anaMs * 0.95 + (CACurrentMediaTime() - a0) * 1000 * 0.05
        let wantJ = wantsJPEG(), wantH = wantsHEVC(), wantP = wantsPreview()
        guard wantJ || wantH || wantP else { return }
        let (rot, q, sat, con, blk) = lock.withLock { (rotation, quality, saturation, contrast, black) }
        let (wm, tn) = lock.withLock { (warm, tint) }
        var img = CIImage(cvPixelBuffer: pb)
        var shown = CGRect(x: 0, y: 0, width: 1, height: 1) // the part of the sensor the picture shows
        let (on, zoom) = lock.withLock { (framing, softZoom) }
        let W = img.extent.width, H = img.extent.height
        let upright = rot == 90 || rot == 270
        if on || upright || abs(Double(W / H) - 16.0 / 9) > 0.01 {
            // Auto-frame, or a phone standing upright: crop a 16:9 landscape window (centred when not framing).
            let win: CGRect
            if on {
                win = framingWindow(rotation: rot, zoom: zoom, sensorAspect: Double(H / W))
            } else {
                let ws = FrameMath.windowSize(rotation: rot, zoom: 1, sensorAspect: Double(H / W))
                win = CGRect(x: 0.5 - ws.w / 2, y: 0.5 - ws.h / 2, width: ws.w, height: ws.h)
            }
            lock.withLock { window = win }
            shown = win
            let r = CGRect(x: win.minX * W, y: (1 - win.maxY) * H, width: win.width * W, height: win.height * H).integral
            img = Camera.fit(img.cropped(to: r)) // output 1920×1080 whatever the capture size
        } else if max(img.extent.width, img.extent.height) > 1920 {
            img = Camera.fit(img) // 4K capture → 1080p stream
        }
        if shown.width == 1, shown.height == 1 { lock.withLock { window = shown } }
        // Geometry first (turn upright, level), then all colour work in one sRGB pass, dither last in it.
        switch rot {
        case 90: img = img.oriented(.right)
        case 180: img = img.oriented(.down)
        case 270: img = img.oriented(.left)
        default: break
        }
        // Rolling the phone by +β about its z axis makes gravity read -β; the rear camera (looking along -z)
        // then sees the scene turned clockwise, so the picture is turned back by +β: angle = -tilt.
        // Below 0.5° nobody sees the tilt, so the frame isn't resampled for it. Above, only the part past
        // 0.5° is corrected, so the turn and its zoom grow from zero: a hard on/off at 0.5° made the picture
        // jump (turn + 1.6 % zoom) each time sensor noise crossed it.
        let (lv, tl) = lock.withLock { (level, tilt) }
        let dead = 0.5 * .pi / 180
        if lv, abs(tl) > dead { img = Camera.leveled(img, angle: -(tl - (tl > 0 ? dead : -dead))) }
        let (cube, look) = lock.withLock { (hueCube, lutCube) }
        let e0 = img.extent
        // Grade in gamma-encoded sRGB, like a photo editor, not in CoreImage's linear space.
        img = img.applyingFilter("CILinearToSRGBToneCurve")
        // The look first (it expects Rec.709 video, like a camera's picture), then the sliders on top of it.
        if let look {
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": look.size, "inputCubeData": look.data])
        }
        if sat != 1 || con != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: sat, kCIInputContrastKey: con, kCIInputBrightnessKey: 0])
        }
        if let cube {
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 32, "inputCubeData": cube])
        }
        if blk != 0 || wm != 0 || tn != 0 {
            // Levels: crush (blk > 0) maps blk→0; lift (blk < 0) maps 0→-blk.
            let scale = blk > 0 ? 1 / (1 - blk) : 1 + blk
            let bias = blk > 0 ? -blk / (1 - blk) : -blk
            // Manual balance as channel gains (warm: more red, less blue; tint: less green = magenta),
            // normalised so brightness stays the same. Same pass as the levels.
            var (gr, gg, gb) = (1 + 0.12 * wm, 1 - 0.08 * tn, 1 - 0.12 * wm)
            let y = 0.2126 * gr + 0.7152 * gg + 0.0722 * gb
            gr /= y; gg /= y; gb /= y
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale * gr, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale * gg, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale * gb, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        // Dither before the 8-bit output, in sRGB (where the 8-bit steps are), so smooth gradients like a lit
        // wall don't break into bands.
        if let gain = faceLight(extent: e0, shown: shown, rotation: rot) {
            img = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain]).cropped(to: e0)
        }
        img = img.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: dither.cropped(to: e0)])
            .cropped(to: e0)
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
        // Preview: a plain 1/3 scale (bilinear), so the whole picture is only evaluated at 640×360; Lanczos
        // needed the full 1080p frame first and cost ~4 ms for a small control-page picture.
        previewTick &+= 1
        // The control-page preview at half the frame rate: plenty to adjust settings by, half the JPEG work.
        if wantP, previewTick % 2 == 0, let data = jpeg(img.transformed(by: CGAffineTransform(scaleX: 1.0 / 3, y: 1.0 / 3)), quality: 0.5) {
            onFrame?(data, true) // control-page preview: 640×360, light enough not to crowd the camera's Wi‑Fi
        }
        let t1 = CACurrentMediaTime()
        encMs = encMs * 0.9 + (t1 - t0) * 1000 * 0.1
        let captured = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if captured.isFinite, hostNow > captured { pipeMs = pipeMs * 0.9 + (hostNow - captured) * 1000 * 0.1 }
    }

    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func jpeg(_ img: CIImage, quality: Double) -> Data? {
        ci.jpegRepresentation(of: img, colorSpace: srgb,
                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }

}
