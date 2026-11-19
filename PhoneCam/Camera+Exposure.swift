import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion
import PhoneCamCore

/// Exposure: shutter limits, tap to focus/expose, highlight guard.
extension Camera {
    func maxZoom(_ d: AVCaptureDevice) -> CGFloat { min(d.maxAvailableVideoZoomFactor, 10) }

    func maxShutter(_ d: AVCaptureDevice) -> Double {
        min(d.activeFormat.maxExposureDuration.seconds, 1.0 / Double(effFps))
    }

    func clampDuration(_ d: AVCaptureDevice, _ t: CMTime) -> CMTime {
        let s = min(maxShutter(d), max(d.activeFormat.minExposureDuration.seconds, t.seconds.isFinite ? t.seconds : 1.0 / 60))
        return CMTime(seconds: s, preferredTimescale: 1_000_000)
    }

    /// (u, v) are 0…1 on the picture as shown (after rotation); map back to sensor coordinates.
    func tap(u: Double, v: Double) {
        releaseSteady() // a tap meters a new spot: auto again first (held by steady auto → running)
        let (r, on, win) = lock.withLock { (rotation, framing, window) }
        let w = FrameMath.toSensor(u: u, v: v, rotation: r)
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

    // MARK: highlight guard

    /// videoQueue, 3 times a second: in auto exposure, metering on the face lets a white wall or a window
    /// behind blow out. When more than 2% of the picture is clipped, pull the exposure down while the face
    /// stays bright enough (up to -1.5 EV below the slider; -0.7 with no face); back up once it's safe.
    func guardHighlights(_ pb: CVPixelBuffer) {
        guard skinMeasureFrame % 10 == 5 else { return }
        // Held by steady auto: the exposure isn't moving, so the guard waits (its offset stays as it is).
        if lock.withLock({ steadyExpHeld }) { return }
        let auto = device?.exposureMode == .continuousAutoExposure
        guard auto else {
            if hlOffset != 0 { hlOffset = 0; applyBias() }
            return
        }
        let img = CIImage(cvPixelBuffer: pb)
        let sx = 96 / img.extent.width, sy = 54 / img.extent.height
        let small = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var px = [UInt8](repeating: 0, count: 96 * 54 * 4)
        ci.render(small, toBitmap: &px, rowBytes: 96 * 4, bounds: CGRect(x: 0, y: 0, width: 96, height: 54),
                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var clipped = 0
        for i in stride(from: 0, to: px.count, by: 4) where max(px[i], px[i + 1], px[i + 2]) >= 245 { clipped += 1 }
        let frac = Double(clipped) / Double(96 * 54)
        // The face wins: never darken it below a natural level for the sake of a window or a lamp.
        let face = CACurrentMediaTime() - faceLuma.time < 1 ? faceLuma.value : nil
        let floor: Float = face == nil ? -0.7 : -1.5
        var o = hlOffset
        if let face, face < 0.30 { o = min(0, o + 0.1) }
        else if frac > 0.02, face.map({ $0 > 0.35 }) ?? true { o = max(floor, o - 0.1) }
        else if frac < 0.005 { o = min(0, o + 0.05) }
        guard o != hlOffset else { return }
        hlOffset = o
        applyBias()
    }

    /// The exposure bias: the EV slider plus the highlight guard.
    func applyBias() {
        let b = lock.withLock { userEV } + hlOffset
        withDevice { d in d.setExposureTargetBias(min(d.maxExposureTargetBias, max(d.minExposureTargetBias, b)), completionHandler: nil) }
    }

    /// Custom exposure (call with the device locked). A flicker-free shutter the sensor can't hit exactly
    /// (iPhone 16 Pro, 4K: 0.03 s comes out as 0.0287 s) is stepped down one flicker period at a time, with the
    /// ISO raised to keep the brightness, so the lamps never show rolling bands.
    func setCustomExposure(_ d: AVCaptureDevice, shutter: Double, iso: Float) {
        let f = d.activeFormat
        let dur = clampDuration(d, CMTime(seconds: shutter, preferredTimescale: 1_000_000))
        d.setExposureModeCustom(duration: dur, iso: min(f.maxISO, max(f.minISO, iso))) { [weak self] _ in
            self?.queue.async {
                guard let self, let d = self.device, d.exposureMode == .custom else { return }
                let period = 1 / Double(2 * self.mainsHz)
                let want = dur.seconds, got = d.exposureDuration.seconds
                let steps = want / period
                guard want >= period * 1.5, abs(steps - steps.rounded()) < 0.01, abs(got - want) / want > 0.02 else { return }
                let lower = (steps.rounded() - 1) * period
                self.withDevice { d in self.setCustomExposure(d, shutter: lower, iso: iso * Float(want / lower)) }
            }
        }
    }
}
