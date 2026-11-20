import AVFoundation
import CoreImage
import QuartzCore
import PhoneCamCore

/// The auto operator: steady auto exposure and white balance, face light with a soft vignette, auto tone.
/// All cheap: steady auto only drives the camera once a second, the light is one gradient in the existing
/// colour pass, and the tone goes into the colour cube that is already there.
extension Camera {
    // MARK: steady auto

    /// queue: forget the holds (whoever calls this sets the camera's modes itself).
    func resetSteady() {
        expHold.reset(); wbHold.reset(); wbRef = nil
        lock.withLock { steadyExpHeld = false }
        steadyWBHeld = false
    }

    /// queue: steady auto was turned off: give exposure and white balance back to auto if they were held.
    func releaseSteady() {
        let e = lock.withLock { steadyExpHeld }, w = steadyWBHeld
        resetSteady()
        withDevice { d in
            if e, d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if w, d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
    }

    private static func gainsDistance(_ a: AVCaptureDevice.WhiteBalanceGains, _ b: AVCaptureDevice.WhiteBalanceGains) -> Double {
        let r = Double(a.redGain / a.greenGain) / Double(b.redGain / b.greenGain)
        let bl = Double(a.blueGain / a.greenGain) / Double(b.blueGain / b.greenGain)
        return max(abs(r - 1), abs(bl - 1))
    }

    /// queue, once a second: hold auto exposure and white balance while the light stays the same; let them
    /// run again when it really changes (more than 0.6 EV, or 8 % in colour, for 2 s), then hold again.
    func checkSteady() {
        guard steadyOn, !asleep, let d = device else { return }
        let held = lock.withLock { steadyExpHeld }
        // Exposure, only when it is meant to be auto (not Lock or Manual).
        let expAuto = !expLock && (d.exposureMode == .continuousAutoExposure || (d.exposureMode == .locked && held))
        if expAuto, let a = expHold.step(Double(d.exposureTargetOffset)) {
            withDevice { d in
                if a == .hold, d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                if a == .release, d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
            lock.withLock { steadyExpHeld = a == .hold && d.exposureMode == .locked }
        }
        // White balance (Auto or Skin; not Lock or a set temperature). While auto runs: how much the gains
        // moved in the last second; while held: how far the scene's grey-world balance is from when it was held.
        let wbAuto = d.whiteBalanceMode == .continuousAutoWhiteBalance || (d.whiteBalanceMode == .locked && steadyWBHeld)
        guard wbAuto else { return }
        let gains = steadyWBHeld ? d.grayWorldDeviceWhiteBalanceGains : d.deviceWhiteBalanceGains
        let dist = wbRef.map { Camera.gainsDistance(gains, $0) } ?? 1
        if !steadyWBHeld { wbRef = gains }
        if let a = wbHold.step(dist) {
            withDevice { d in
                if a == .hold, d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
                if a == .release, d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            steadyWBHeld = a == .hold && d.whiteBalanceMode == .locked
            wbRef = steadyWBHeld ? d.grayWorldDeviceWhiteBalanceGains : nil
        }
    }

    // MARK: face light

    /// videoQueue: a gain image for the graded (sRGB) picture of `extent`: a little light on the face,
    /// a soft vignette toward the corners. It follows the face smoothly and fades out when the face is gone.
    func faceLight(extent e: CGRect, shown: CGRect, rotation: Int) -> CIImage? {
        let (on, amt, face, faceT) = lock.withLock { (lightOn, lightAmt, faceRect, faceRectTime) }
        guard on, amt > 0.01 else { return nil }
        let now = CACurrentMediaTime()
        var target: CGPoint?
        var size = lightSize
        if let f = face, now - faceT < 1, shown.width > 0, shown.height > 0 {
            let c = CGPoint(x: (f.midX - shown.minX) / shown.width, y: (f.midY - shown.minY) / shown.height)
            if c.x > -0.1, c.x < 1.1, c.y > -0.1, c.y < 1.1 {
                target = FrameMath.toDisplay(c, rotation: rotation)
                size = Double(rotation == 90 || rotation == 270 ? f.width / shown.width : f.height / shown.height)
            }
        }
        if let t = target {
            lightCenter.x += (t.x - lightCenter.x) * 0.08
            lightCenter.y += (t.y - lightCenter.y) * 0.08
            lightSize += (size - lightSize) * 0.08
        }
        lightFace += ((target == nil ? 0 : 1) - lightFace) * 0.04
        let luma = now - faceLuma.time < 1 ? faceLuma.value : nil
        let l = AutoOperator.light(size: e.size, faceCenter: lightCenter, faceSize: lightSize, faceLuma: luma, strength: amt)
        let faceGain = 1 + (l.face - 1) * lightFace
        // Raw gains in the working space, so the multiply works on the sRGB-encoded values as they are.
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let c0 = CIColor(red: faceGain, green: faceGain, blue: faceGain, alpha: 1, colorSpace: cs),
              let c1 = CIColor(red: l.edge, green: l.edge, blue: l.edge, alpha: 1, colorSpace: cs),
              let g = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: e.minX + l.center.x, y: e.maxY - l.center.y),
                "inputRadius0": l.radius0, "inputRadius1": l.radius1, "inputColor0": c0, "inputColor1": c1])?.outputImage
        else { return nil }
        return g.cropped(to: e)
    }

    // MARK: auto tone

    /// videoQueue, every 2 s: the brightness histogram of the part the stream shows (before our grading),
    /// and the tone moved slowly toward what the last ~30 s suggest.
    func analyzeTone(_ pb: CVPixelBuffer) {
        guard accentFrame % 60 == 0 else { return }
        let (on, win, reset) = lock.withLock { () -> (Bool, CGRect, Bool) in
            let r = toneReset; toneReset = false
            return (toneOn, window, r)
        }
        if reset { toneTracker.reset() }
        guard on else { return }
        let img = source(pb)
        let w = 64, h = 36
        let small = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ci.render(small, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var hist = [Double](repeating: 0, count: 64)
        for row in 0..<h {
            let y = (Double(row) + 0.5) / Double(h)
            guard y >= win.minY, y <= win.maxY else { continue }
            for col in 0..<w {
                let x = (Double(col) + 0.5) / Double(w)
                guard x >= win.minX, x <= win.maxX else { continue }
                let i = (row * w + col) * 4
                let l = 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
                hist[min(63, Int(l / 256 * 64))] += 1
            }
        }
        let t = toneTracker.update(AutoOperator.tone(histogram: hist, strength: 1))
        let changed = lock.withLock { () -> Bool in
            let big = abs(t.contrast - autoTone.contrast) > 0.005 || abs(t.mids - autoTone.mids) > 0.005
                || abs(t.black - autoTone.black) > 0.003 || abs(t.white - autoTone.white) > 0.003
            if big { autoTone = t }
            return big
        }
        if changed { queue.async { self.rebuildCube() } }
    }
}
