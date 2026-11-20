import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion
import PhoneCamCore

/// Skin-tone white balance and the colour cube (HSL per colour, see ColorCube in PhoneCamCore).
extension Camera {
    /// videoQueue: average colour of the centre of the face, a few times a second.
    func measureSkin(_ pb: CVPixelBuffer) {
        skinMeasureFrame += 1
        guard skinMeasureFrame % 8 == 0 else { return }
        let (rect, t) = lock.withLock { (faceRect, faceRectTime) }
        guard let rect, CACurrentMediaTime() - t < 1 else { return }
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        // Middle 40% of the face box: nose and cheeks, away from hair, hat and background.
        let inner = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
        let r = CGRect(x: inner.minX * w, y: (1 - inner.maxY) * h, width: inner.width * w, height: inner.height * h)
        guard r.width > 4, r.height > 4 else { return }
        let img = source(pb)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [Float](repeating: 0, count: 4)
        ci.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                  format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        let (R, G, B) = (Double(px[0]), Double(px[1]), Double(px[2]))
        // Apple Log: the developing exposure follows the face, so a window behind you or a lamp switched on does
        // not leave it dark or burnt. Held while no face is seen; back to none when switched off.
        if lock.withLock({ logOn && faceExpOn }) {
            logStops = min(AppleLog.maxLift, max(AppleLog.maxCut, logStops + AppleLog.exposureStep(faceLuma: 0.2126 * R + 0.7152 * G + 0.0722 * B)))
        } else if logStops != 0 { logStops = 0 }
        faceLuma = (pow(max(0, 0.2126 * R + 0.7152 * G + 0.0722 * B), 1 / 2.2), CACurrentMediaTime())
        guard G > 0.003 else { return } // too dark to judge
        // Bright light can push the red channel of skin to its limit; then the face reads "not red
        // enough" and the loop would add red. Skip such samples.
        guard max(R, G, B) < 0.85 else { return }
        queue.async { self.correctSkinHue(r: R, g: G, b: B) }
    }

    /// queue: Skin mode. Auto white balance stays on for the whole scene; the face is fixed by rotating
    /// the hue of skin tones only (a narrow band around the face's own hue) toward natural skin. Saturation
    /// and brightness stay as they are, and the rest of the picture (background, clothes) is untouched.
    func correctSkinHue(r: Double, g: Double, b: Double) {
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
    static let skinHueDeg = 20.0

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

    /// queue: rebuild the colour cube from HSL, the saturation slider and the current skin correction.
    func rebuildCube() {
        // HSL is either manual (the sliders) or auto (from the scene), never both. HSL auto 2 also turns hues
        // (clothes toward clean colours) and gives skin a tan instead of the bands, at the same strength.
        let vib = lock.withLock { vibrance }
        let (h, tone, tan) = lock.withLock { () -> (HSL, AutoOperator.Tone, Double) in
            var auto = HSL().addingSaturation(autoSat)
            if portraitOn { auto.hue = autoHue }
            var tone = toneOn ? autoTone : AutoOperator.Tone()
            // the points belong to the Apple Log picture (the iPhone sets its own in its HDR picture), and have a switch
            if !(pointsOn && logOn) { tone.black = 0; tone.white = 0 }
            return (accentsOn ? auto : hsl, tone, accentsOn && portraitOn ? accentAmt : 0)
        }
        let shift = skinWB ? skinShift : 0
        builtShift = shift
        let cube = ColorCube.make(hsl: h, skinCenter: faceHueDeg ?? Camera.skinHueDeg, skinShift: shift,
                                  tone: tone, skinTan: tan, vibrance: vib)
        lock.withLock { hueCube = cube }
    }

    /// videoQueue, every 2 s (60 frames): look at the background's colours (only the part the stream shows,
    /// without the face) and move the auto accents slowly toward what the last ~30 s suggest.
    func analyzeAccents(_ pb: CVPixelBuffer) {
        accentFrame += 1
        guard accentFrame % 60 == 30 else { return }
        let (on, portrait, amt, win, face, faceT, reset) = lock.withLock { () -> (Bool, Bool, Double, CGRect, CGRect?, Double, Bool) in
            let r = accentReset; accentReset = false
            return (accentsOn, portraitOn, accentAmt, window, faceRect, faceRectTime, r)
        }
        if reset { accentTracker.reset(); portraitHue.reset(); portraitSat.reset() }
        guard on else { return }
        let img = source(pb)
        let w = 96, h = 54
        let small = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ci.render(small, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let seen = CACurrentMediaTime() - faceT < 2 ? face : nil
        var v: [Double], hues = [Double](repeating: 0, count: 8)
        if portrait {
            let rot = lock.withLock { rotation }
            let skin = faceHueDeg ?? Camera.skinHueDeg
            let t = Portrait.target(Portrait.analyze(rgba: px, width: w, height: h, window: win, face: seen, rotation: rot,
                                                     skinHue: skin), strength: amt)
            v = portraitSat.update(t.sat)
            hues = portraitHue.update(t.hue)
        } else {
            let stats = Accents.analyze(rgba: px, width: w, height: h, window: win, face: seen)
            v = accentTracker.update(Accents.target(stats, strength: amt, faceInView: seen != nil))
        }
        let changed = lock.withLock { () -> Bool in
            let big = zip(v, autoSat).contains { abs($0 - $1) > 0.02 } || zip(hues, autoHue).contains { abs($0 - $1) > 0.02 }
            if big { autoSat = v; autoHue = hues }
            return big
        }
        if changed { queue.async { self.rebuildCube() } }
    }
}
