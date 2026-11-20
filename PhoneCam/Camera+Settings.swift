import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion
import PhoneCamCore

/// Settings API (call on `queue`): saved settings, `apply`, presets, reset.
extension Camera {
    // MARK: settings API (call on `queue`)

    static let persisted = ["lens", "fps", "cap", "proc", "rot", "q", "sat", "vib", "con", "black", "hsl", "accents", "accentAmt", "steady", "faceExp", "light", "lightAmt", "tone", "skinWarm", "warm", "tint", "zoom", "wb", "exp", "mains", "frame", "level", "teeth"]

    static func saved() -> [String: String] {
        var p = (UserDefaults.standard.dictionary(forKey: "settings") as? [String: String]) ?? [:]
        if p["rot"] == nil { p["rot"] = "auto" } // picked from gravity (a Mac mount gives 180)
        p["face"] = "1" // always start following the face, whatever was chosen last time
        if p["wb"] == nil { p["wb"] = "auto" }
        if p["frame"] == nil { p["frame"] = "1" }
        if p["level"] == nil { p["level"] = "1" }
        if p["q"] == nil { p["q"] = "0.95" } // maximum JPEG quality (USB carries it easily)
        if p["exp"] == nil || p["exp"] == "manual" { p["exp"] = "auto" }
        // Default grade: neutral, the picture as the camera sees it.
        if p["sat"] == nil { p["sat"] = "1" }
        if p["vib"] == nil { p["vib"] = "0.35" }
        if p["con"] == nil { p["con"] = "1" }
        if p["black"] == nil { p["black"] = "0" }
        if p["lens"] == nil { p["lens"] = "wide" }
        if p["fps"] == nil { p["fps"] = "30" }
        if p["cap"] == nil { p["cap"] = "4k" }
        if p["proc"] == nil { p["proc"] = "log" }
        if p["zoom"] == nil { p["zoom"] = "1.15" }
        if p["skinWarm"] == nil { p["skinWarm"] = "0" }
        if p["warm"] == nil { p["warm"] = "0" }
        if p["tint"] == nil { p["tint"] = "0" }
        if p["mains"] == nil { p["mains"] = "auto" }
        if p["accents"] == nil { p["accents"] = "0" }
        if p["steady"] == nil { p["steady"] = "1" }
        if p["light"] == nil { p["light"] = "1" }
        if p["lightAmt"] == nil { p["lightAmt"] = "0.5" }
        if p["tone"] == nil { p["tone"] = "1" }
        if p["faceExp"] == nil { p["faceExp"] = "1" }
        if p["accentAmt"] == nil { p["accentAmt"] = "0.6" }
        return Camera.migrated(p)
    }

    /// Settings and presets from before HSL: the Red / Green / Blue saturation sliders become HSL.
    static func migrated(_ p0: [String: String]) -> [String: String] {
        var p = p0
        let old = ["red", "green", "blue"].map { p.removeValue(forKey: $0) }
        if p["hsl"] == nil {
            let v = old.map { Double($0 ?? "") ?? 1 }
            p["hsl"] = HSL.fromOldSliders(red: v[0], green: v[1], blue: v[2]).string
        }
        return p
    }

    func apply(_ p: [String: String]) {
        if p["reset"] == "1" { return resetToDefaults() }
        if p["chart"] == "1" { lock.withLock { chartUntil = CACurrentMediaTime() + 12 }; return }
        if p["sleep"] == "1" { queue.async { self.sleepSoon = true }; return }
        if let raw = p["presetSave"] {
            if let all = Presets.saving(raw, settings: Camera.saved(), into: Camera.presets) { Camera.presets = all }
            return
        }
        if let name = p["presetDelete"] { Camera.presets[name] = nil; return }
        if let name = p["presetLoad"] {
            if let preset = Camera.presets[name] { apply(Camera.migrated(preset)) }
            return
        }
        let keep = p.filter { Camera.persisted.contains($0.key) }
        if !keep.isEmpty {
            UserDefaults.standard.set(Camera.saved().merging(keep) { $1 }, forKey: "settings")
        }
        if let v = p["lens"], v != lens {
            switchLens(v) // a new lens starts in auto exposure
            if p["exp"] == nil { lockExposureLater(Camera.saved()["exp"]) }
        }
        if let v = p["cap"], v == "4k" || v == "1080", v != cap {
            cap = v
            switchLens(lens) // new capture size; the camera restarts in auto exposure
            if p["exp"] == nil { lockExposureLater(Camera.saved()["exp"]) }
        }
        if let v = p["proc"], v == "log" || v == "hdr", v != proc {
            proc = v
            switchLens(lens) // the other colour mode of the format; the camera restarts in auto exposure
            if p["exp"] == nil { lockExposureLater(Camera.saved()["exp"]) }
        }
        if let v = p["fps"], let f = Int(v), f == 30 || f == 60, f != fps {
            fps = f
            darkLimited = false; darkSince = nil; brightSince = nil
            switchLens(lens) // the 10-bit format for this frame rate; the camera restarts in auto exposure
            if p["exp"] == nil { lockExposureLater(Camera.saved()["exp"]) }
        }
        if let v = p["rot"] {
            if v == "auto" { lock.withLock { autoRot = true } }
            else if let r = Int(v), [0, 90, 180, 270].contains(r) { lock.withLock { autoRot = false; rotation = r } }
        }
        if let v = p["q"], let q = Double(v) {
            let qq = min(0.98, max(0.3, q))
            lock.withLock { quality = qq }
            encoder.setBitrate(FrameMath.bitrate(quality: qq))
        }
        if let v = p["sat"], let x = Double(v) { lock.withLock { saturation = min(2, max(0, x)) } }
        if let v = p["vib"], let x = Double(v) { lock.withLock { vibrance = min(1, max(0, x)) } }
        if let v = p["con"], let x = Double(v) { lock.withLock { contrast = min(1.5, max(0.5, x)) } }
        if let v = p["black"], let x = Double(v) { lock.withLock { black = min(0.1, max(-0.1, x)) } }
        if let v = p["warm"], let x = Double(v) { lock.withLock { warm = min(1, max(-1, x)) } }
        if let v = p["tint"], let x = Double(v) { lock.withLock { tint = min(1, max(-1, x)) } }
        if let v = p["skinWarm"], let x = Double(v) { skinWarm = min(1, max(-1, x)) }
        if let v = p["steady"] { steadyOn = v == "1"; if !steadyOn { releaseSteady() } }
        if p["exp"] != nil || p["wb"] != nil || p["temp"] != nil || p["iso"] != nil || p["shutter"] != nil { resetSteady() }
        if p["light"] != nil || p["lightAmt"] != nil {
            lock.withLock {
                if let v = p["light"] { lightOn = v == "1" }
                if let v = p["lightAmt"], let x = Double(v) { lightAmt = min(1, max(0, x)) }
            }
        }
        if let v = p["teeth"], let x = Double(v) { lock.withLock { teethAmount = min(1, max(0, x)) } }
        if let v = p["faceExp"] { lock.withLock { faceExpOn = v == "1" } }
        if let v = p["tone"] {
            lock.withLock { toneOn = v == "1"; if !toneOn { autoTone = AutoOperator.Tone(); toneReset = true } }
            rebuildCube()
        }
        if p["accents"] != nil || p["accentAmt"] != nil {
            lock.withLock {
                if let v = p["accents"] {
                    let on = v == "1" || v == "2", portrait = v == "2"
                    if on != accentsOn || portrait != portraitOn {
                        accentReset = true
                        autoSat = [Double](repeating: 0, count: 8)
                        autoHue = [Double](repeating: 0, count: 8)
                    }
                    accentsOn = on
                    portraitOn = portrait
                }
                if let v = p["accentAmt"], let x = Double(v) { accentAmt = min(1, max(0, x)) }
            }
            rebuildCube()
        }
        if p["hsl"] != nil || p["sat"] != nil || p["vib"] != nil {
            if let v = p["hsl"] { lock.withLock { hsl = HSL(string: v) } }
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
        // Manual focus / point focus turns face following off until the app restarts (Face is the default).
        if p["tap"] != nil || p["lensPos"] != nil || p["focus"] == "lock" { followFace = false }
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

        if let v = p["mains"], ["auto", "50", "60"].contains(v), v != mains {
            mains = v
            if expLock, p["exp"] == nil { apply(["exp": "lock"]) } // move the locked shutter to the new safe value
        }
        if let v = p["exp"] {
            expLock = v == "lock"
            withDevice { d in
                switch v {
                case "lock":
                    // Freeze the current brightness with the slowest flicker-free shutter the frame rate allows
                    // (1/30 s at 30 fps on 60 Hz power, 3/100 s on 50 Hz): same exposure, lower ISO, less noise,
                    // and no rolling bands from the lamps.
                    if d.isExposureModeSupported(.custom) {
                        let target = Flicker.safeShutter(mains: mainsHz, longest: maxShutter(d))
                        let iso = Float(Double(d.iso) * d.exposureDuration.seconds / target)
                        setCustomExposure(d, shutter: target, iso: iso)
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
            lock.withLock { userEV = f }
            applyBias()
        }
        if p["iso"] != nil || p["shutter"] != nil {
            expLock = false
            withDevice { d in
                guard d.isExposureModeSupported(.custom) else { return }
                var iso = d.iso
                if let v = p["iso"], let i = Float(v) { iso = i }
                var dur = d.exposureDuration.seconds
                if let v = p["shutter"], let s = Double(v) { dur = Flicker.snap(s, mains: mainsHz, longest: maxShutter(d)) }
                setCustomExposure(d, shutter: dur, iso: iso)
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

    // MARK: presets

    static var presets: [String: [String: String]] {
        get { (UserDefaults.standard.dictionary(forKey: "presets") as? [String: [String: String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "presets") }
    }

    /// Forget every saved setting and apply the defaults from `saved()`. Exposure runs in auto for a
    /// few seconds and then locks, as at launch.
    func resetToDefaults() {
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
    func lockExposureLater(_ exp: String?) {
        guard exp == "lock" else { return }
        queue.asyncAfter(deadline: .now() + 3) {
            if Camera.saved()["exp"] == "lock" { self.apply(["exp": "lock"]) }
        }
    }
}
