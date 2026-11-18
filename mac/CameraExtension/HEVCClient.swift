import CoreMedia
import Foundation
import Network
import QuartzCore
import VideoToolbox

/// Reads the HEVC stream (GET /hevc) and decodes it in hardware into 1920×1080 BGRA frames.
/// Wire format: see `HEVCEncoder` in the iOS app: [u8 type][u32 BE length][payload],
/// type 1 = parameter sets, type 2 = one access unit (4-byte length-prefixed NAL units).
/// Reconnects after errors and when no frame arrives for 2 s.
final class HEVCClient {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer) -> Void
    private var conn: NWConnection?
    private var buffer = Data()
    private var inHeader = true
    private var lastFrame = 0.0
    private var running = false
    private var watchdog: DispatchSourceTimer?

    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?

    init(host: String, port: UInt16, queue: DispatchQueue, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.queue = queue
        self.onFrame = onFrame
    }

    // All methods run on `queue`.

    func start() {
        running = true
        connect()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.running, CACurrentMediaTime() - self.lastFrame > 2 else { return }
            self.conn?.cancel() // the state handler reconnects
        }
        t.resume()
        watchdog = t
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        conn?.cancel()
        conn = nil
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        decoder = nil
        format = nil
    }

    private func connect() {
        guard running else { return }
        buffer.removeAll(keepingCapacity: true)
        inHeader = true
        lastFrame = CACurrentMediaTime()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let c = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.scheduleReconnect(for: c)
            default: break
            }
        }
        c.start(queue: queue)
        c.send(content: Data("GET /hevc HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n".utf8),
               completion: .contentProcessed { _ in })
        read(c)
    }

    private func scheduleReconnect(for c: NWConnection) {
        guard c === conn else { return }
        conn = nil
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running, self.conn == nil else { return }
            self.connect()
        }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if done || err != nil { c.cancel() } else { self.read(c) }
        }
    }

    private func parse() {
        if inHeader {
            guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16 * 1024 { conn?.cancel() } // not our server
                return
            }
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            inHeader = false
        }
        while buffer.count >= 5 {
            let b = buffer.startIndex
            let type = buffer[b]
            let len = Int(UInt32(buffer[b + 1]) << 24 | UInt32(buffer[b + 2]) << 16 | UInt32(buffer[b + 3]) << 8 | UInt32(buffer[b + 4]))
            guard len < 16 << 20 else { conn?.cancel(); return } // garbage
            guard buffer.count >= 5 + len else { return }
            let payload = Data(buffer[(b + 5)..<(b + 5 + len)])
            buffer.removeSubrange(b..<(b + 5 + len))
            if type == 1 { configure(payload) } else if type == 2 { decode(payload) }
        }
    }

    /// Parameter sets → format description; a new decoder only when the format changed.
    private func configure(_ p: Data) {
        guard let count = p.first, count > 0 else { return }
        var sets: [Data] = []
        var i = p.startIndex + 1
        for _ in 0..<Int(count) {
            guard i + 4 <= p.endIndex else { return }
            let n = Int(UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3]))
            i += 4
            guard i + n <= p.endIndex else { return }
            sets.append(Data(p[i..<(i + n)]))
            i += n
        }
        var fmt: CMVideoFormatDescription?
        let status: OSStatus = sets.withUnsafeBufferPointers { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        }
        guard status == noErr, let fmt else { return }
        if let old = format, let d = decoder, CMFormatDescriptionEqual(old, otherFormatDescription: fmt),
           VTDecompressionSessionCanAcceptFormatDescription(d, formatDescription: fmt) {
            return
        }
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        let dest: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(outWidth),
            kCVPixelBufferHeightKey: Int(outHeight),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var d: VTDecompressionSession?
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec,
                                           imageBufferAttributes: dest, outputCallback: nil,
                                           decompressionSessionOut: &d) == noErr, let d else { return }
        VTSessionSetProperty(d, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = d
        format = fmt
    }

    private func decode(_ frame: Data) {
        guard let fmt = format, let d = decoder else { return } // wait for the first keyframe's config
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: frame.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return }
        let copied = frame.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: frame.count) == kCMBlockBufferNoErr
        }
        guard copied else { return }
        var sb: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return }
        // Synchronous: the handler runs before this returns, still on `queue`.
        VTDecompressionSessionDecodeFrame(d, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image, let self else { return }
            self.lastFrame = CACurrentMediaTime()
            self.onFrame(image)
        }
    }
}

private extension Array where Element == Data {
    /// Pointers and sizes for CoreMedia's parameter-set API, valid inside `body`.
    func withUnsafeBufferPointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let copies = map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let ptrs = copies.map { UnsafePointer($0) }
        let sizes = map(\.count)
        return ptrs.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { ss in body(pp.baseAddress!, ss.baseAddress!) } }
    }
}
