import CoreMediaIO
import CoreVideo
import CoreText
import Foundation
import ImageIO
import IOKit.audio
import QuartzCore
import os.log

private let log = Logger(subsystem: "PhoneCam", category: "camera")
let frameRate: Int32 = 30
let outWidth: Int32 = 1920
let outHeight: Int32 = 1080

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "PhoneCam")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("PhoneCam: addDevice failed: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "PhoneCam" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

/// One 1920×1080 BGRA stream. Frames come from the MJPEG stream on localhost:4747; each decoded frame is
/// sent at once. When nothing arrives (phone app closed), a "no signal" card keeps the camera alive.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: StreamSource!
    private var format: CMFormatDescription!
    private var pool: CVPixelBufferPool!
    private let queue = DispatchQueue(label: "phonecam.camera", qos: .userInteractive)
    private var streaming = 0
    private var client: MJPEGClient?
    private var idleTimer: DispatchSourceTimer?
    private var lastSent = 0.0
    private var lastBuffer: CVPixelBuffer?
    private lazy var placeholder: CVPixelBuffer? = makePlaceholder()

    init(localizedName: String) {
        super.init()
        // A fixed ID so apps remember the camera between launches.
        let id = UUID(uuidString: "6B1F0C2E-4B47-4C1A-9E5D-2A7C3F4E4747")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: id, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: outWidth, height: outHeight, extensions: nil, formatDescriptionOut: &format)
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: outWidth,
            kCVPixelBufferHeightKey: outHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format,
            maxFrameDuration: CMTime(value: 1, timescale: frameRate),
            minFrameDuration: CMTime(value: 1, timescale: frameRate),
            validFrameDurations: nil)
        let streamID = UUID(uuidString: "0D3E8A51-7C2B-4E8F-A1B6-5F9E2C3D4747")!
        streamSource = StreamSource(localizedName: "PhoneCam.Video", streamID: streamID, streamFormat: streamFormat, device: device)
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("PhoneCam: addStream failed: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "PhoneCam" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        queue.async {
            self.streaming += 1
            guard self.streaming == 1 else { return }
            log.info("start streaming")
            let c = MJPEGClient(host: "127.0.0.1", port: 4747, queue: self.queue) { [weak self] jpeg in
                self?.receive(jpeg)
            }
            self.client = c
            c.start()
            // Keep frames flowing while the phone is silent: repeat the last frame, then show the card.
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.idleTick() }
            t.resume()
            self.idleTimer = t
        }
    }

    func stopStreaming() {
        queue.async {
            self.streaming = max(0, self.streaming - 1)
            guard self.streaming == 0 else { return }
            log.info("stop streaming")
            self.client?.stop()
            self.client = nil
            self.idleTimer?.cancel()
            self.idleTimer = nil
            self.lastBuffer = nil
        }
    }

    // queue
    private func receive(_ jpeg: Data) {
        guard streaming > 0, let pb = decode(jpeg) else { return }
        lastBuffer = pb
        send(pb)
    }

    // queue
    private func idleTick() {
        let now = CACurrentMediaTime()
        guard now - lastSent > 0.2 else { return }
        if now - lastSent > 2 { lastBuffer = nil } // phone gone: switch to the card
        if let pb = lastBuffer ?? placeholder { send(pb) }
    }

    // queue
    private func send(_ pb: CVPixelBuffer) {
        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        timing.duration = CMTime(value: 1, timescale: frameRate)
        var sb: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
                                                     makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                                     sampleTiming: &timing, sampleBufferOut: &sb)
        guard err == noErr, let sb else { return }
        streamSource.stream.send(sb, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
        lastSent = CACurrentMediaTime()
    }

    /// JPEG → 1920×1080 BGRA, letterboxed if the aspect differs.
    private func decode(_ jpeg: Data) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return draw { ctx, w, h in
            let s = min(w / CGFloat(img.width), h / CGFloat(img.height))
            let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
        }
    }

    private func makePlaceholder() -> CVPixelBuffer? {
        draw { ctx, w, h in
            ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w / 2 - 14, y: h / 2 + 40, width: 28, height: 28))
            let lines: [(String, CGFloat, CGFloat)] = [
                ("PhoneCam: no signal", 44, h / 2 - 20),
                ("Open the PhoneCam app on the iPhone and the PhoneCam app on this Mac", 26, h / 2 - 70),
            ]
            for (text, size, y) in lines {
                let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
                let attr = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.85, alpha: 1),
                ])
                let line = CTLineCreateWithAttributedString(attr)
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: (w - CGFloat(width)) / 2, y: y)
                CTLineDraw(line, ctx)
            }
        }
    }

    private func draw(_ body: (CGContext, CGFloat, CGFloat) -> Void) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: Int(outWidth), height: Int(outHeight), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(outWidth), h = CGFloat(outHeight)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        body(ctx, w, h)
        return pb
    }
}

// MARK: - Stream

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: frameRate) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex { activeFormatIndex = i }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { (device.source as? DeviceSource)?.startStreaming() }
    func stopStream() throws { (device.source as? DeviceSource)?.stopStreaming() }
}
