import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion
import PhoneCamCore

/// Orientation, levelling, face following and auto-frame.
extension Camera {
    /// Gravity → roll of the phone around the camera axis, relative to the nearest upright orientation.
    /// About 10 updates a second, smoothed; nothing when the phone lies flat.
    func startMotion() {
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
                let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY)].map { FrameMath.toDisplay($0, rotation: r) }
                let top = min(corners[0].y, corners[1].y), height = abs(corners[0].y - corners[1].y)
                let head = FrameMath.toSensor(u: (corners[0].x + corners[1].x) / 2, v: top + height * 0.15, rotation: r)
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

    // MARK: auto-frame

    /// videoQueue: crop window (sensor-normalized, top-left origin) that keeps the face
    /// horizontally centred with the eyes a bit above the middle. Moves like a camera operator:
    /// starts only after a clear offset, eases in, stops when close.
    func framingWindow(rotation: Int, zoom: Double, sensorAspect: Double) -> CGRect {
        let ws = FrameMath.windowSize(rotation: rotation, zoom: zoom, sensorAspect: sensorAspect)
        let (pt, t) = lock.withLock { (trackPoint, trackTime) }
        var goal = frameCenter
        if let pt, CACurrentMediaTime() - t < 2 {
            // Where the face centre should sit inside the window, in sensor orientation.
            let spot = FrameMath.toSensor(u: 0.5, v: 0.45, rotation: rotation)
            goal = CGPoint(x: pt.x - ws.w * (spot.x - 0.5), y: pt.y - ws.h * (spot.y - 0.5))
        }
        let hw = ws.w / 2, hh = ws.h / 2
        goal.x = min(1 - hw, max(hw, goal.x))
        goal.y = min(1 - hh, max(hh, goal.y))
        frameCenter.x = min(1 - hw, max(hw, frameCenter.x)) // zoom or orientation may have changed
        frameCenter.y = min(1 - hh, max(hh, frameCenter.y))
        let size = max(ws.w, ws.h)
        let dist = hypot(goal.x - frameCenter.x, goal.y - frameCenter.y)
        if dist > size * 0.06 { framingMoving = true }   // ignore small moves
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
    static func fit(_ img: CIImage) -> CIImage {
        let e = img.extent
        let long = max(e.width, e.height)
        let outW = (e.width / long * 1920 / 2).rounded() * 2
        let outH = (e.height / long * 1920 / 2).rounded() * 2
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: outW / e.width, y: outH / e.height)))
            .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    }
}
