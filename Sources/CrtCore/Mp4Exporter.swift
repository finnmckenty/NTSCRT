import Foundation
import AVFoundation
import Metal
import CoreVideo
import CrtAppBridge

/// Encodes a source video through the CRT pipeline into an .mp4 (H.264/HEVC)
/// or .mov (ProRes). Audio (if any) is re-encoded to AAC.
public final class Mp4Exporter {

    /// Output codec. Scanline/mask detail is high-frequency content that
    /// low-bitrate H.264 smears — HEVC keeps it at the same bitrate, and
    /// ProRes preserves it outright (the right choice for edit workflows).
    public enum Codec: String, CaseIterable, Sendable {
        case h264 = "H.264"
        case hevc = "HEVC"
        case prores422 = "ProRes 422"
        case prores422HQ = "ProRes 422 HQ"

        public var isProRes: Bool { self == .prores422 || self == .prores422HQ }
        /// ProRes must live in a QuickTime container.
        public var fileExtension: String { isProRes ? "mov" : "mp4" }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            case .prores422: return .proRes422
            case .prores422HQ: return .proRes422HQ
            }
        }
        var avFileType: AVFileType { isProRes ? .mov : .mp4 }
    }

    public struct Settings {
        public var outputURL: URL
        public var outputWidth: Int
        public var outputHeight: Int
        public var downscale: DownscaleSpec?
        public var presetPath: String           // .slangp file
        public var codec: Codec
        /// Target average bitrate in bits/s (H.264/HEVC only; ProRes ignores it).
        public var averageBitrate: Int?
        /// How many times the content plays through. 1 = once (normal).
        /// Written as repeated passes so the file itself is longer — for
        /// places that don't loop a video on playback.
        public var loopCount: Int
        public init(outputURL: URL, outputWidth: Int, outputHeight: Int,
                    downscale: DownscaleSpec?, presetPath: String,
                    codec: Codec = .h264, averageBitrate: Int? = nil,
                    loopCount: Int = 1) {
            self.loopCount = max(1, loopCount)
            self.outputURL = outputURL
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
            self.downscale = downscale
            self.presetPath = presetPath
            self.codec = codec
            self.averageBitrate = averageBitrate
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case writerInit(String)
        case noVideoTrack
        case encodeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .writerInit(let s): return "writer init: \(s)"
            case .noVideoTrack: return "no video track"
            case .encodeFailed(let s): return "encode failed: \(s)"
            }
        }
    }

    private let context: MetalContext
    private let pipeline: Pipeline
    public init(context: MetalContext) {
        self.context = context
        self.pipeline = Pipeline(context: context)
    }

    /// Copy an audio sample buffer with its timestamps shifted — needed when
    /// the same audio is written more than once for a looped export.
    static func offsetSampleBuffer(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else { return nil }
        for i in 0..<count {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sb,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    /// Run the export. Calls `progress(0...1)` as it goes. Async, throws.
    /// `ntscSettingsJSON` non-nil enables the ntsc-rs stage per frame (the
    /// exporter builds its own NtscStage so the preview's instance is never
    /// touched off the main thread).
    /// - Parameter frameParams: optional per-frame values (the keyframe
    ///   timeline). Called with (frameIndex, totalFrames) on the export
    ///   thread; must be self-contained.
    public func export(source: VideoSource,
                       paramValues: [String: Float],
                       settings: Settings,
                       ntscSettingsJSON: String? = nil,
                       frameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async throws {

        var ntscStage: NtscStage? = nil
        if let json = ntscSettingsJSON {
            guard let stage = NtscStage() else {
                throw Error.encodeFailed("ntsc-rs stage unavailable (dylib not loaded)")
            }
            try stage.setSettingsJSON(json)
            ntscStage = stage
        }

        // Fresh chain just for this export, on the same queue.
        let chain = try LRShaderChain(presetPath: settings.presetPath,
                                      commandQueue: context.queue)
        for (n, v) in paramValues { try? chain.setParameter(n, value: v) }

        // Remove any existing file at the output path.
        try? FileManager.default.removeItem(at: settings.outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL,
                                       fileType: settings.codec.avFileType)
        } catch {
            throw Error.writerInit("\(error)")
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: settings.outputWidth,
            AVVideoHeightKey: settings.outputHeight,
        ]
        if !settings.codec.isProRes {
            let bitrate = settings.averageBitrate
                ?? max(2_000_000, settings.outputWidth * settings.outputHeight * 4)
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.outputWidth,
            kCVPixelBufferHeightKey as String: settings.outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pbAttrs
        )
        guard writer.canAdd(videoInput) else { throw Error.writerInit("cannot add video input") }
        writer.add(videoInput)

        // Audio: read decoded LPCM from source and re-encode to AAC into the
        // output. (True compressed-passthrough is fragile across sample rates
        // and channel layouts; an AAC re-encode is robust and ~free.)
        let audioTracks = try await source.asset.loadTracks(withMediaType: .audio)
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        // Each loop pass needs its own reader — an AVAssetReader can't rewind.
        let asset = source.asset
        let makeAudioReader: @Sendable () -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput)? = {
            guard let track = audioTracks.first,
                  let r = try? AVAssetReader(asset: asset) else { return nil }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard r.canAdd(out) else { return nil }
            r.add(out)
            r.startReading()
            return (r, out)
        }
        if let audioTrack = audioTracks.first {
            let aReader = try AVAssetReader(asset: source.asset)
            let lpcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: lpcmSettings)
            if aReader.canAdd(aOut) { aReader.add(aOut) }

            let audioOutSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutSettings)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
                audioOutput = aOut
                audioReader = aReader
                aReader.startReading()
            }
        }

        guard writer.startWriting() else {
            throw Error.writerInit("startWriting: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let videoReader = try source.makeSequentialReader()
        let totalFrames = source.totalFrames
        let loops = max(1, settings.loopCount)
        let clipDuration = CMTime(seconds: source.durationSeconds, preferredTimescale: 600)
        var frameIndex = 0

        // Guard against scanline banding at small output sizes (ScanlineGrid).
        let chainInput = ScanlineGrid.chainInputSize(width: Int(source.pixelSize.width),
                                                    height: Int(source.pixelSize.height),
                                                    downscale: settings.downscale)
        let supersample = SupersampledPass.make(device: context.device,
                                                chainInput: chainInput,
                                                target: (settings.outputWidth, settings.outputHeight))

        // Render target reused across frames (private).
        guard let target = makeRenderTarget(device: context.device,
                                            width: settings.outputWidth,
                                            height: settings.outputHeight) else {
            throw Error.encodeFailed("makeRenderTarget")
        }

        // Texture cache reused across frames (allocating per-frame is ~10× slower).
        var sharedCacheOpt: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, context.device, nil, &sharedCacheOpt)
        guard let sharedCache = sharedCacheOpt else {
            throw Error.encodeFailed("CVMetalTextureCacheCreate")
        }

        // Drive video AND audio drains concurrently. AVAssetWriter back-
        // pressures when only one stream is being fed, so we cannot drain
        // them serially.
        try await withThrowingTaskGroup(of: Void.self) { group in
            // -- video task --
            group.addTask {
                try await Task.detached { () throws -> Void in
            var pass = 0
            var reader = videoReader
            var passFrame = 0
            while true {
                if !videoInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                guard let frame = reader.nextFrame() else {
                    // End of this pass. Loop again from the top if asked,
                    // with a fresh reader; the clip's own timestamps restart
                    // at zero, so each pass is shifted by its duration.
                    pass += 1
                    if pass < loops, let next = try? source.makeSequentialReader() {
                        reader = next
                        passFrame = 0
                        continue
                    }
                    videoInput.markAsFinished()
                    return
                }

                if let perFrame = frameParams?(passFrame, totalFrames) {
                    if let shader = perFrame.shader {
                        for (n, v) in shader { try? chain.setParameter(n, value: v) }
                    }
                    if let json = perFrame.ntscJSON, let stage = ntscStage {
                        try stage.setSettingsJSON(json)
                    }
                }
                guard let cb = self.context.queue.makeCommandBuffer() else {
                    throw Error.encodeFailed("commandBuffer")
                }
                var frameInput = frame.texture
                var frameDownscale = settings.downscale
                if let stage = ntscStage {
                    frameInput = try self.pipeline.prepareChainInput(
                        source: frame.texture, downscale: frameDownscale,
                        ntsc: stage, frameCount: passFrame + 1)
                    frameDownscale = nil
                }
                if let supersample {
                    try supersample.encode(into: cb, pipeline: self.pipeline, chain: chain,
                                           inputTexture: frameInput, outputTexture: target,
                                           downscale: frameDownscale, frameCount: frameIndex + 1)
                } else {
                    try self.pipeline.encode(into: cb, chain: chain,
                                             inputTexture: frameInput,
                                             outputTexture: target,
                                             downscale: frameDownscale,
                                             frameCount: frameIndex + 1)
                }

                var pb: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                }
                guard let pb else {
                    throw Error.encodeFailed("pixel buffer pool")
                }

                var cvtex: CVMetalTexture?
                let rc = CVMetalTextureCacheCreateTextureFromImage(
                    nil, sharedCache, pb, nil,
                    .bgra8Unorm,
                    CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                    0, &cvtex
                )
                guard rc == kCVReturnSuccess, let cvtex,
                      let pbTex = CVMetalTextureGetTexture(cvtex),
                      let blit = cb.makeBlitCommandEncoder() else {
                    throw Error.encodeFailed("cv tex / blit")
                }
                blit.copy(from: target,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: settings.outputWidth,
                                              height: settings.outputHeight, depth: 1),
                          to: pbTex,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()

                let pts = pass == 0
                    ? frame.presentationTime
                    : CMTimeAdd(frame.presentationTime,
                                CMTimeMultiply(clipDuration, multiplier: Int32(pass)))
                if !adaptor.append(pb, withPresentationTime: pts) {
                    throw Error.encodeFailed("adaptor.append: \(writer.error?.localizedDescription ?? "?")")
                }

                // Release Metal-cached textures so the cache doesn't bloat.
                CVMetalTextureCacheFlush(sharedCache, 0)

                    frameIndex += 1
                    passFrame += 1
                    let p = min(1.0, Double(frameIndex) / Double(totalFrames * loops))
                    progress(p)
                }
                }.value
            }

            // -- audio task (only if there's an audio track) --
            if let audioInput, let audioOutput, let firstAudioReader = audioReader {
                let makeAudio = makeAudioReader
                group.addTask {
                    try await Task.detached { () throws -> Void in
                        var output = audioOutput
                        var keepAlive: AVAssetReader? = firstAudioReader
                        var pass = 0
                        while true {
                            if !audioInput.isReadyForMoreMediaData {
                                Thread.sleep(forTimeInterval: 0.005)
                                continue
                            }
                            if let sb = output.copyNextSampleBuffer() {
                                // Later passes have to be shifted, or the
                                // writer rejects timestamps that go backwards.
                                let shifted = pass == 0
                                    ? sb
                                    : (Mp4Exporter.offsetSampleBuffer(
                                        sb, by: CMTimeMultiply(clipDuration, multiplier: Int32(pass))) ?? sb)
                                if !audioInput.append(shifted) {
                                    throw Error.encodeFailed("audio append: \(writer.error?.localizedDescription ?? "?")")
                                }
                            } else {
                                pass += 1
                                if pass < loops, let next = makeAudio() {
                                    keepAlive = next.reader
                                    output = next.output
                                    _ = keepAlive
                                    continue
                                }
                                audioInput.markAsFinished()
                                return
                            }
                        }
                    }.value
                }
            }

            try await group.waitForAll()
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw Error.encodeFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        progress(1.0)
    }

    /// Render a still image into a video: `totalFrames` frames at `fps`,
    /// each run through the full pipeline with an advancing frame counter
    /// (so frame-seeded VHS noise, jitter, and interlacing animate).
    ///
    /// `frameParams`, if given, is called per frame with (frameIndex,
    /// totalFrames) and may return new shader params and/or ntsc settings
    /// JSON to apply for that frame — the keyframe-animation hook. It runs
    /// on the export thread and must be self-contained.
    public func exportStill(source: MTLTexture,
                            totalFrames: Int,
                            fps: Int,
                            paramValues: [String: Float],
                            settings: Settings,
                            ntscSettingsJSON: String? = nil,
                            frameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? = nil,
                            progress: @escaping @Sendable (Double) -> Void) async throws {

        var ntscStage: NtscStage? = nil
        if let json = ntscSettingsJSON {
            guard let stage = NtscStage() else {
                throw Error.encodeFailed("ntsc-rs stage unavailable (dylib not loaded)")
            }
            try stage.setSettingsJSON(json)
            ntscStage = stage
        }

        let chain = try LRShaderChain(presetPath: settings.presetPath,
                                      commandQueue: context.queue)
        for (n, v) in paramValues { try? chain.setParameter(n, value: v) }

        try? FileManager.default.removeItem(at: settings.outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL,
                                       fileType: settings.codec.avFileType)
        } catch {
            throw Error.writerInit("\(error)")
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: settings.outputWidth,
            AVVideoHeightKey: settings.outputHeight,
        ]
        if !settings.codec.isProRes {
            let bitrate = settings.averageBitrate
                ?? max(2_000_000, settings.outputWidth * settings.outputHeight * 4)
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.outputWidth,
            kCVPixelBufferHeightKey as String: settings.outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pbAttrs
        )
        guard writer.canAdd(videoInput) else { throw Error.writerInit("cannot add video input") }
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw Error.writerInit("startWriting: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        guard let target = makeRenderTarget(device: context.device,
                                            width: settings.outputWidth,
                                            height: settings.outputHeight) else {
            throw Error.encodeFailed("makeRenderTarget")
        }

        // Small outputs would otherwise alias the shader's scanlines into
        // bands (see ScanlineGrid); nil when the size is already fine.
        let chainInput = ScanlineGrid.chainInputSize(width: source.width, height: source.height,
                                                    downscale: settings.downscale)
        let supersample = SupersampledPass.make(device: context.device,
                                                chainInput: chainInput,
                                                target: (settings.outputWidth, settings.outputHeight))

        var sharedCacheOpt: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, context.device, nil, &sharedCacheOpt)
        guard let sharedCache = sharedCacheOpt else {
            throw Error.encodeFailed("CVMetalTextureCacheCreate")
        }

        try await Task.detached { () throws -> Void in
            for frameIndex in 0..<totalFrames {
                while !videoInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }

                if let perFrame = frameParams?(frameIndex, totalFrames) {
                    if let shader = perFrame.shader {
                        for (n, v) in shader { try? chain.setParameter(n, value: v) }
                    }
                    if let json = perFrame.ntscJSON, let stage = ntscStage {
                        try stage.setSettingsJSON(json)
                    }
                }

                guard let cb = self.context.queue.makeCommandBuffer() else {
                    throw Error.encodeFailed("commandBuffer")
                }
                var frameInput = source
                var frameDownscale = settings.downscale
                if let stage = ntscStage {
                    frameInput = try self.pipeline.prepareChainInput(
                        source: source, downscale: frameDownscale,
                        ntsc: stage, frameCount: frameIndex + 1,
                        // Stills: one fixed image for every frame.
                        sourceVersion: 0)
                    frameDownscale = nil
                }
                if let supersample {
                    try supersample.encode(into: cb, pipeline: self.pipeline, chain: chain,
                                           inputTexture: frameInput, outputTexture: target,
                                           downscale: frameDownscale, frameCount: frameIndex + 1)
                } else {
                    try self.pipeline.encode(into: cb, chain: chain,
                                             inputTexture: frameInput,
                                             outputTexture: target,
                                             downscale: frameDownscale,
                                             frameCount: frameIndex + 1)
                }

                var pb: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                }
                guard let pb else {
                    throw Error.encodeFailed("pixel buffer pool")
                }

                var cvtex: CVMetalTexture?
                let rc = CVMetalTextureCacheCreateTextureFromImage(
                    nil, sharedCache, pb, nil,
                    .bgra8Unorm,
                    CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                    0, &cvtex
                )
                guard rc == kCVReturnSuccess, let cvtex,
                      let pbTex = CVMetalTextureGetTexture(cvtex),
                      let blit = cb.makeBlitCommandEncoder() else {
                    throw Error.encodeFailed("cv tex / blit")
                }
                blit.copy(from: target,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: settings.outputWidth,
                                              height: settings.outputHeight, depth: 1),
                          to: pbTex,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()

                let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
                if !adaptor.append(pb, withPresentationTime: time) {
                    throw Error.encodeFailed("adaptor.append: \(writer.error?.localizedDescription ?? "?")")
                }
                CVMetalTextureCacheFlush(sharedCache, 0)
                progress(min(1.0, Double(frameIndex + 1) / Double(totalFrames)))
            }
            videoInput.markAsFinished()
        }.value

        await writer.finishWriting()
        if writer.status == .failed {
            throw Error.encodeFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        progress(1.0)
    }
}
