import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion

/// Sleep when nobody watches, and the heat limit.
extension Camera {
    /// queue: once a second, wake up for a viewer or go to sleep after `sleepAfter` seconds without one.
    func startSleepTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkHeat()
            self.checkDark()
            self.checkSteady()
            let watched = self.wantsHEVC() || self.wantsJPEG() || self.wantsPreview()
            let now = CACurrentMediaTime()
            if watched {
                self.lastViewer = now
                if self.asleep {
                    self.asleep = false
                    self.session.startRunning()
                    self.restoreZoom()           // startRunning resets the zoom factor
                    self.encoder.requestKeyframe()
                }
            } else if !self.asleep, self.sleepSoon || now - self.lastViewer > Camera.sleepAfter {
                self.sleepSoon = false
                self.asleep = true
                self.session.stopRunning()
                self.measuredFps = 0
            }
        }
        t.resume()
        idleTimer = t
    }

    /// queue, once a second: hot → 1080p 30 fps; a minute of cool → back to the chosen size and rate.
    func checkHeat() {
        let th = ProcessInfo.processInfo.thermalState
        let now = CACurrentMediaTime()
        if th == .serious || th == .critical {
            coolSince = nil
            guard !heatLimited, cap == "4k" || fps == 60 else { return }
            heatLimited = true
        } else {
            guard heatLimited else { return }
            if th == .fair || th == .nominal { coolSince = coolSince ?? now } else { coolSince = nil }
            guard let c = coolSince, now - c >= 60 else { return }
            heatLimited = false
            coolSince = nil
        }
        switchLens(lens) // the camera restarts in auto exposure
        lockExposureLater(Camera.saved()["exp"])
    }

    /// queue, once a second: at 60 fps in auto exposure, a dark room (shutter at 1/60 s and ISO above half
    /// its range for 3 s) drops to 30 fps, so the shutter can stay open twice as long; back to 60 fps after
    /// 10 s of light that 1/60 s could handle at a quarter of the ISO range.
    func checkDark() {
        guard fps == 60, !heatLimited, !asleep, let d = device, d.exposureMode == .continuousAutoExposure else {
            darkSince = nil; brightSince = nil
            return
        }
        let now = CACurrentMediaTime()
        let maxISO = Double(d.activeFormat.maxISO)
        let iso60 = Double(d.iso) * d.exposureDuration.seconds * 60 // the ISO the same light needs at 1/60 s
        if !darkLimited {
            let dark = d.exposureDuration.seconds >= 0.9 / 60 && Double(d.iso) > 0.5 * maxISO
            darkSince = dark ? (darkSince ?? now) : nil
            guard let t = darkSince, now - t >= 3 else { return }
            darkLimited = true
        } else {
            brightSince = iso60 < 0.25 * maxISO ? (brightSince ?? now) : nil
            guard let t = brightSince, now - t >= 10 else { return }
            darkLimited = false
        }
        darkSince = nil; brightSince = nil
        applyFps() // same format, new frame rate: no camera restart
    }
}
