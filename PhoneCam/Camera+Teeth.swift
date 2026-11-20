import CoreImage
import QuartzCore
import Vision
import PhoneCamCore

/// Teeth: inside the open mouth only (Vision's inner lip contour), less yellow and a little lighter.
extension Camera {
    /// videoQueue: find the mouth on its own queue (Vision face landmarks, ~10 times a second, only while the
    /// Teeth slider is above 0); frames never wait for it.
    func requestMouth(_ pb: CVPixelBuffer, rotation: Int) {
        let now = CACurrentMediaTime()
        let busy = lock.withLock { () -> Bool in
            if mouthBusy || now - mouthLastRun < 0.1 { return true }
            mouthBusy = true
            mouthLastRun = now
            return false
        }
        guard !busy else { return }
        mouthQueue.async {
            defer { self.lock.withLock { self.mouthBusy = false } }
            let orient: CGImagePropertyOrientation
            switch rotation {
            case 90: orient = .right
            case 180: orient = .down
            case 270: orient = .left
            default: orient = .up
            }
            // a third of 4K is plenty for landmarks; Vision wants the face upright
            let small = self.source(pb).transformed(by: CGAffineTransform(scaleX: 1.0 / 3, y: 1.0 / 3))
            try? VNImageRequestHandler(ciImage: small, orientation: orient).perform([self.landmarks])
            let area = { (f: VNFaceObservation) in f.boundingBox.width * f.boundingBox.height }
            guard let face = self.landmarks.results?.max(by: { area($0) < area($1) }),
                  let inner = face.landmarks?.innerLips else { return }
            // landmarks are relative to the face box, in the upright picture with a bottom-left origin
            let bb = face.boundingBox
            let pts = inner.normalizedPoints.map { CGPoint(x: bb.minX + $0.x * bb.width, y: bb.minY + $0.y * bb.height) }
            guard let l = pts.min(by: { $0.x < $1.x }), let r = pts.max(by: { $0.x < $1.x }),
                  let top = pts.map(\.y).max(), let bottom = pts.map(\.y).min(), r.x - l.x > 0.01 else { return }
            let c = CGPoint(x: (l.x + r.x) / 2, y: (top + bottom) / 2)
            let m = Mouth(left: FrameMath.toSensor(u: l.x, v: 1 - l.y, rotation: rotation),
                          right: FrameMath.toSensor(u: r.x, v: 1 - r.y, rotation: rotation),
                          center: FrameMath.toSensor(u: c.x, v: 1 - c.y, rotation: rotation),
                          open: Double((top - bottom) / (r.x - l.x)))
            self.lock.withLock { self.mouth = m; self.mouthTime = CACurrentMediaTime() }
        }
    }

    /// videoQueue: the picture with whiter teeth if the mouth is open and was seen in the last 0.6 s (fading out
    /// over the last 0.3 s). `img` is the cropped picture in sensor orientation, `win` the sensor part it shows.
    func withWhiterTeeth(_ img: CIImage, window win: CGRect) -> CIImage {
        let (amount, found) = lock.withLock { (teethAmount, mouth.map { ($0, CACurrentMediaTime() - mouthTime) }) }
        guard amount > 0.01, let (m, age) = found, age < 0.6, m.open > 0.12 else { return img }
        let fade = age < 0.3 ? 1 : (0.6 - age) / 0.3
        return whitenTeeth(img, mouth: m, window: win, amount: amount * fade)
    }

    /// Inside a soft ellipse over the opened mouth: yellowish light tones (teeth) lose colour and brighten a
    /// little; reds and pinks (lips, gums, tongue) are left alone by the cube.
    private func whitenTeeth(_ img: CIImage, mouth m: Mouth, window win: CGRect, amount a: Double) -> CIImage {
        let e = img.extent
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: e.minX + (p.x - win.minX) / win.width * e.width,
                    y: e.minY + (1 - (p.y - win.minY) / win.height) * e.height)
        }
        let l = px(m.left), r = px(m.right), c = px(m.center)
        let w = hypot(r.x - l.x, r.y - l.y)
        guard w > 10 else { return img }
        let h = max(4, w * CGFloat(m.open))
        let angle = atan2(r.y - l.y, r.x - l.x)
        // a unit soft disc stretched to the mouth opening and turned along the line between the corners
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.6, "inputRadius1": 1.0,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])!.outputImage!.transformed(by: CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: angle).scaledBy(x: w / 2, y: h / 2 * 1.1))
        let q = (a * 20).rounded() / 20
        if teethCube?.amount != q { teethCube = (q, Camera.teethCube(amount: q)) }
        let area = CGRect(x: c.x - w, y: c.y - w, width: 2 * w, height: 2 * w).intersection(e)
        let whiter = img.cropped(to: area).applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": 16, "inputCubeData": teethCube!.data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        return whiter.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask.cropped(to: e)]).cropped(to: e)
    }

    /// 16³ cube for teeth: light yellow-orange tones (hue ~25–65°) lose most of their colour and get a little
    /// lighter; reds and pinks (lips, gums, tongue) and dark tones stay as they are.
    static func teethCube(amount a: Double) -> Data {
        let n = 16
        var out = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
                    var (rr, gg, bb) = (r, g, b)
                    let v = max(r, g, b)
                    if let h = hue(r, g, b, minChroma: 0.02), h >= 15, h <= 75 {
                        let band = h < 25 ? (h - 15) / 10 : h > 65 ? (75 - h) / 10 : 1 // soft edges
                        let light = min(1, max(0, (v - 0.35) / 0.3))
                        let k = a * band * light
                        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        let f = 1 - 0.7 * k              // less yellow
                        let lift = 1 + 0.08 * k          // a little brighter
                        rr = (y + (r - y) * f) * lift; gg = (y + (g - y) * f) * lift; bb = (y + (b - y) * f) * lift
                    }
                    out[i] = Float(min(1, max(0, rr))); out[i + 1] = Float(min(1, max(0, gg)))
                    out[i + 2] = Float(min(1, max(0, bb))); out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// The open mouth, sensor-normalized (top-left origin); `open` = opening height / width.
struct Mouth {
    var left, right, center: CGPoint
    var open: Double
}
