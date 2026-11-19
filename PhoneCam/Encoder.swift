import CoreImage
import QuartzCore
import CoreMedia
import VideoToolbox
import PhoneCamCore

/// Hardware HEVC encoder for the /hevc stream: 1920×1080, real time, no frame reordering (no added
/// latency), a keyframe every 2 s and on request (a new viewer starts at once).
///
/// Wire format (after the HTTP header), one message after another:
///   [u8 type][u32 big-endian length][payload]
///   type 1 = config: [u8 count] then per parameter set (VPS, SPS, PPS) [u32 BE length][bytes]
///   type 2 = frame:  HEVC access unit, NAL units with 4-byte big-endian lengths (as VideoToolbox writes them)
/// A keyframe is always sent right after a config message.
final class HEVCEncoder {
    static let width = 1920, height = 1080

    /// Called on VideoToolbox's thread with ready-to-send messages for one frame, and whether it is a keyframe.
    var onOutput: ((Data, Bool) -> Void)?

    private let ci: CIContext
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()
    private var forceKey = true
    private var rate = BitrateController(target: 24_000_000) // under lock: Quality slider target, adapted to the link
    private var appliedBitrate = 0
    private var broken = false
    private var lastOutput = 0.0, sessionStart = 0.0   // under lock

    private func resetSession() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        lock.withLock { broken = false; forceKey = true }
    }

    /// Bitrate actually used now (bits/s).
    var currentBitrate: Int { lock.withLock { rate.current } }

    /// Server: a viewer was still busy with the previous frame (the link is too slow for this bitrate).
    func reportCongestion() { lock.withLock { rate.reportCongestion() } }

    init(ci: CIContext) { self.ci = ci }

    func requestKeyframe() { lock.withLock { forceKey = true } }

    func setBitrate(_ bps: Int) { lock.withLock { rate.target = bps } }

    /// The camera's frame rate, for the encoder's rate control (applied to the running session at once).
    func setFrameRate(_ fps: Int) {
        lock.withLock { frameRate = fps }
        if let s = session { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber) }
    }
    private var frameRate = 30

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    /// videoQueue: render the finished picture (origin 0,0, 1920×1080) and encode it. Returns the rendered
    /// frame, so the JPEG preview can reuse it instead of rendering the whole picture a second time.
    @discardableResult
    func encode(_ img: CIImage, pts: CMTime) -> CVPixelBuffer? {
        if session == nil { makeSession() }
        guard let session, let pool else { return nil }
        let (key, bps) = lock.withLock { () -> (Bool, Int) in
            let k = forceKey
            forceKey = false
            return (k, rate.tick(now: CACurrentMediaTime())) // once a second: -30% on congestion, +15% when clean
        }
        if bps != appliedBitrate { applyBitrate(session, bps) }

        // The session's own pool hands out buffers in the layout the hardware encoder reads directly, so the
        // picture is rendered straight into encoder memory with no conversion copy; ours is only a fallback.
        var out: CVPixelBuffer?
        let src = VTCompressionSessionGetPixelBufferPool(session) ?? pool
        guard CVPixelBufferPoolCreatePixelBuffer(nil, src, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        ci.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: HEVCEncoder.width, height: HEVCEncoder.height),
                  colorSpace: HEVCEncoder.srgb)

        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self else { return }
            guard status == noErr, let sb else { if status != noErr { self.lock.withLock { self.broken = true } }; return }
            self.output(sb)
        }
        // iOS kills the hardware encoder while the app is in the background or the phone is locked:
        // start a new one (with a keyframe) instead of encoding into a dead session forever.
        // Same if it silently stops giving frames for 2 s.
        let now = CACurrentMediaTime()
        let silent = lock.withLock { now - max(lastOutput, sessionStart) > 2 }
        if st != noErr || silent || lock.withLock({ broken }) { resetSession() }
        return pb
    }

    private func makeSession() {
        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: HEVCEncoder.width,
            kCVPixelBufferHeightKey: HEVCEncoder.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs, &pool)
        var s: VTCompressionSession?
        // Low-latency rate control where the encoder supports it; plain real-time otherwise.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        if VTCompressionSessionCreate(allocator: nil, width: Int32(HEVCEncoder.width), height: Int32(HEVCEncoder.height),
                                      codecType: kCMVideoCodecType_HEVC, encoderSpecification: lowLatency,
                                      imageBufferAttributes: attrs, compressedDataAllocator: nil, outputCallback: nil,
                                      refcon: nil, compressionSessionOut: &s) != noErr {
            VTCompressionSessionCreate(allocator: nil, width: Int32(HEVCEncoder.width), height: Int32(HEVCEncoder.height),
                                       codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                       imageBufferAttributes: attrs, compressedDataAllocator: nil, outputCallback: nil,
                                       refcon: nil, compressionSessionOut: &s)
        }
        guard let s else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        let fps = lock.withLock { frameRate }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // A keyframe every 5 s: keyframes are the biggest frames, and the Mac asks for one at once whenever
        // it loses a packet or a new viewer starts, so a short interval only costs bitrate and smoothness.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps * 5 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 5 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        appliedBitrate = 0
        lock.withLock { sessionStart = CACurrentMediaTime() }
    }

    private func applyBitrate(_ s: VTCompressionSession, _ bps: Int) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Cap peaks at 1.5× the average over one second, so keyframes don't burst the link.
        let limits = [Double(bps) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        appliedBitrate = bps
    }

    private func output(_ sb: CMSampleBuffer) {
        lock.withLock { lastOutput = CACurrentMediaTime() }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        var msg = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb), let config = HEVCEncoder.parameterSets(fmt) {
            HEVCWire.append(&msg, type: HEVCWire.config, config)
        }
        let n = CMBlockBufferGetDataLength(block)
        var frame = Data(count: n)
        let ok = frame.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: raw.baseAddress!) == kCMBlockBufferNoErr
        }
        guard ok else { return }
        HEVCWire.append(&msg, type: HEVCWire.frame, frame)
        onOutput?(msg, isKey)
    }

    private static func parameterSets(_ fmt: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil) == noErr, count > 0
        else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let ptr
            else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        return HEVCWire.parameterSets(sets)
    }
}
