import AVFoundation
import CoreImage
import QuartzCore
import CoreMotion
import PhoneCamCore

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
                    self.restartAt = now
                    self.session.startRunning()
                    self.startMotion()
                    self.restoreZoom()           // startRunning resets the zoom factor
                    self.encoder.requestKeyframe()
                } else if CameraWatchdog.shouldRestart(now: now, watched: true, asleep: false,
                                                       interrupted: self.interrupted != nil,
                                                       lastFrame: self.lock.withLock({ self.lastFrameAt }),
                                                       lastStart: self.restartAt) {
                    self.restartSession()        // watched, running, yet no frames: a stop iOS didn't report
                }
            } else if !self.asleep, self.sleepSoon || now - self.lastViewer > Camera.sleepAfter {
                self.sleepSoon = false
                self.asleep = true
                self.session.stopRunning()
                self.motion.stopDeviceMotionUpdates() // levelling and rotation need nothing while asleep
                self.updateStats { $0.fps = 0 }
            }
        }
        t.resume()
        idleTimer = t
    }

    /// Restart the camera after iOS interrupts it (app in the background, camera taken by another app,
    /// Split View, heat) or after a runtime error; the reason goes to /state as `interrupted`.
    func observeSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
            let raw = n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let why: String
            switch raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)) {
            case .videoDeviceNotAvailableInBackground: why = "PhoneCam is in the background on the iPhone"
            case .videoDeviceInUseByAnotherClient: why = "another app uses the iPhone camera"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: why = "Split View or Slide Over on the iPhone"
            case .videoDeviceNotAvailableDueToSystemPressure: why = "iPhone too hot"
            default: why = "stopped by iOS"
            }
            self?.queue.async { self?.interrupted = why }
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.interrupted = nil
                self?.restartSession()
            }
        }
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.queue.async {
                guard let self else { return }
                // Media services reset: wait for the interruption to end, the session restarts then.
                if err?.code == .mediaServicesWereReset, self.interrupted != nil { return }
                self.restartSession()
            }
        }
    }

    /// queue: start the capture again (unless asleep), with the zoom and a keyframe restored.
    func restartSession() {
        guard !asleep else { return }
        restartAt = CACurrentMediaTime()
        if session.isRunning { session.stopRunning() }
        session.startRunning()
        restoreZoom() // startRunning resets the zoom factor
        encoder.requestKeyframe()
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
