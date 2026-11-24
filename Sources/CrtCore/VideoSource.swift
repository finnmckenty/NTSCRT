import Foundation
import AVFoundation
import Metal
import CoreVideo

/// Reads frames from a video file and exposes them as MTLTextures.
///
/// Two modes:
///   - Random access (scrubbing in the UI) via `frame(at:)` — uses
///     `AVAssetImageGenerator` so we can jump to arbitrary times cheaply.
///   - Sequential (export) via `makeSequentialReader()` — returns an iterator
///     wrapping `AVAssetReader` for max throughput on linear playback.
public final class VideoSource {

    public let url: URL
    public let asset: AVAsset
    public let videoTrack: AVAssetTrack
    public let durationSeconds: Double
    public let frameRate: Float
    public let pixelSize: CGSize
    public let totalFrames: Int
    /// One frame's length in seconds: what a frame index is multiplied by
    /// to get its time, everywhere (see `time(ofFrame:)`).
    public let frameSeconds: Double
    /// The same as an exact fraction (1001/30000 s at 29.97 fps), when the
    /// track has one that fits (see `frameLength`).
    private let exactFrameDuration: CMTime?

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let imageGenerator: AVAssetImageGenerator

    public enum Error: Swift.Error, LocalizedError {
        case noVideoTrack
        case textureCacheCreate(CVReturn)
        case readerSetup(String)
        case decodeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "No video track in this file."
            case .textureCacheCreate(let r): return "CVMetalTextureCacheCreate failed (\(r))."
            case .readerSetup(let s): return "AVAssetReader setup failed: \(s)."
            case .decodeFailed(let s): return "decode failed: \(s)."
            }
        }
    }

    public init(url: URL, device: MTLDevice) async throws {
        self.url = url
        self.device = device
        let asset = AVURLAsset(url: url)
        self.asset = asset

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Error.noVideoTrack }
        self.videoTrack = track

        let (duration, fps, size, minFrame) = try await (
            asset.load(.duration),
            track.load(.nominalFrameRate),
            track.load(.naturalSize),
            track.load(.minFrameDuration)
        )
        self.durationSeconds = CMTimeGetSeconds(duration)
        self.frameRate = fps > 0 ? fps : 30
        self.pixelSize = size
        self.totalFrames = max(1, Int((self.durationSeconds * Double(self.frameRate)).rounded()))
        let length = Self.frameLength(minFrameDuration: minFrame, nominalRate: Double(self.frameRate),
                                      durationSeconds: self.durationSeconds, sampleSpan: Self.sampleSpan(of: track))
        self.frameSeconds = length.seconds
        self.exactFrameDuration = length.exact

        var cache: CVMetalTextureCache?
        let r = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard r == kCVReturnSuccess, let cache else {
            throw Error.textureCacheCreate(r)
        }
        self.textureCache = cache

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        self.imageGenerator = gen
    }

    /// Decode the frame nearest to `time` and return it as an MTLTexture,
    /// cropped if asked.
    public func frame(at time: CMTime, crop: SourceCrop? = nil) async throws -> MTLTexture {
        // AVAssetImageGenerator produces a CGImage we then upload via MTKTextureLoader.
        // For fewer copies we could attach a custom output, but for scrubbing this is fine.
        let cgImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Swift.Error>) in
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image, result == .succeeded {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: Error.decodeFailed("AVAssetImageGenerator returned \(result.rawValue)"))
                }
            }
        }
        // CGImage crops in its own pixel space: top row first, like the
        // rest of the pipeline.
        if let crop {
            let r = crop.rect(width: cgImage.width, height: cgImage.height)
            if (r.width, r.height) != (cgImage.width, cgImage.height),
               let cropped = cgImage.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) {
                return try cgImageToTexture(cropped)
            }
        }
        return try cgImageToTexture(cgImage)
    }

    // MARK: - frame index ↔ time
    //
    // One rule for every path: frame i is shown from i × the frame's length.
    // Playback and exports count decoded frames from the start, so they land
    // on that time by themselves; anything that asks the decoder for frame i
    // (scrubbing, a reader starting mid-clip) must ask for the same time.
    // Through 0.28.1 those asked for i / round(fps): 0.1% early at 29.97 and
    // 23.976 fps, so one frame early from frame 1 and 18 frames early ten
    // minutes in, and the clip's last 0.1% couldn't be reached.

    /// From the file's sample table: how many frames follow the first, and
    /// how long after it the last one is shown. Nil when the file has no
    /// table to step through. (Under 2 ms on an 11-minute clip.)
    static func sampleSpan(of track: AVAssetTrack) -> (steps: Int, seconds: Double)? {
        guard track.canProvideSampleCursors,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        let first = cursor.presentationTimeStamp
        let steps = cursor.stepInPresentationOrder(byCount: Int64.max)
        let seconds = CMTimeGetSeconds(CMTimeSubtract(cursor.presentationTimeStamp, first))
        guard steps > 0, seconds.isFinite, seconds > 0 else { return nil }
        return (Int(steps), seconds)
    }

    /// One frame's length. The spacing the sample table shows (last frame's
    /// time ÷ frames after the first), as the track's own fraction when that
    /// fraction puts the last frame within a quarter frame of where it is:
    /// a constant-rate clip, whose frame times are then exact. The track's
    /// `minFrameDuration` can't be taken on its own word: in a file that
    /// keeps time in 1/600 s, 29.97 fps footage has frames of 20 and 21
    /// units and a shortest frame of 1/30 s (AVAssetWriter's default, so
    /// this app's own exports); a clip whose frames vary in length has a
    /// shortest frame that says nothing about where frame i is. Without a
    /// sample table: the track's fraction if the clip's length counted in
    /// it is within a quarter frame of length × nominal rate, else
    /// 1 / the nominal rate.
    static func frameLength(minFrameDuration d: CMTime, nominalRate: Double, durationSeconds: Double,
                            sampleSpan: (steps: Int, seconds: Double)?) -> (seconds: Double, exact: CMTime?) {
        let trackSeconds = d.isNumeric && d.value > 0 ? CMTimeGetSeconds(d) : nil
        if let span = sampleSpan, span.steps > 0, span.seconds > 0 {
            if let trackSeconds, abs(Double(span.steps) * trackSeconds - span.seconds) <= trackSeconds / 4 {
                return (trackSeconds, d)
            }
            return (span.seconds / Double(span.steps), nil)
        }
        let rate = nominalRate > 0 ? nominalRate : 30
        if let trackSeconds, durationSeconds.isFinite,
           abs(durationSeconds / trackSeconds - durationSeconds * rate) <= 0.25 {
            return (trackSeconds, d)
        }
        return (1 / rate, nil)
    }

    /// When frame `index` goes on screen (its presentation time).
    public func time(ofFrame index: Int) -> CMTime {
        if let d = exactFrameDuration { return CMTimeMultiply(d, multiplier: Int32(clamping: index)) }
        return CMTime(seconds: Double(index) * frameSeconds, preferredTimescale: Self.fineTimescale)
    }

    /// `time(ofFrame:)` in seconds.
    public func seconds(ofFrame index: Int) -> Double {
        exactFrameDuration == nil ? Double(index) * frameSeconds : CMTimeGetSeconds(time(ofFrame: index))
    }

    /// The time to ask a decoder for to get frame `index`: the middle of the
    /// frame. Both decoders hand back the frame on screen at the time asked
    /// for (measured: the image generator at zero tolerance, and an asset
    /// reader's first frame), so half a frame of room either way absorbs
    /// rounding and frames that sit slightly off the grid (a file whose
    /// timescale can't hold 1001/30000 s, as AVAssetWriter's default can't).
    func decodeTime(ofFrame index: Int) -> CMTime {
        if let d = exactFrameDuration {
            return CMTimeMultiplyByRatio(d, multiplier: Int32(clamping: 2 * index + 1), divisor: 2)
        }
        return CMTime(seconds: (Double(index) + 0.5) * frameSeconds, preferredTimescale: Self.fineTimescale)
    }

    private static let fineTimescale: CMTimeScale = 1_000_000

    /// A frame as a CGImage, whole (for showing what a crop leaves out).
    public func cgImage(atIndex index: Int) async throws -> CGImage {
        let time = decodeTime(ofFrame: index)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Swift.Error>) in
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image, result == .succeeded {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: Error.decodeFailed("AVAssetImageGenerator returned \(result.rawValue)"))
                }
            }
        }
    }

    public func frame(atIndex index: Int, crop: SourceCrop? = nil) async throws -> MTLTexture {
        try await frame(at: decodeTime(ofFrame: index), crop: crop)
    }

    private func cgImageToTexture(_ cg: CGImage) throws -> MTLTexture {
        let w = cg.width, h = cg.height
        let bpr = w * 4
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: h * bpr)
        let bm: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: bm) else {
            throw Error.decodeFailed("CGContext")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
        )
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else {
            throw Error.decodeFailed("makeTexture")
        }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: bpr)
        }
        return tex
    }

    // MARK: - sequential reader for export

    public final class SequentialReader {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let device: MTLDevice
        let textureCache: CVMetalTextureCache
        /// Frames come out cropped to this, copied into `ring` — a frame's
        /// texture holds until `cropDepth` frames later. Uncropped frames are
        /// the decoder's own buffers, zero-copy.
        let crop: SourceCrop?
        private let ring: CropRing?
        /// A reader started mid-clip stamps its first frame with the time it
        /// was started at (measured; the frame carries nothing saying how
        /// far in that is), not the frame's own: this is the frame's own.
        private var firstFrameTime: CMTime?
        /// More frames than any consumer holds at once (playback: queue +
        /// on screen + previous + the two being processed).
        public static let cropDepth = 12

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput,
             device: MTLDevice, textureCache: CVMetalTextureCache, crop: SourceCrop?,
             firstFrameTime: CMTime? = nil) {
            self.firstFrameTime = firstFrameTime
            self.reader = reader
            self.output = output
            self.device = device
            self.textureCache = textureCache
            self.crop = crop
            self.ring = crop.map { _ in CropRing(device: device, depth: Self.cropDepth) }
            reader.startReading()
        }

        public struct Frame {
            public let texture: MTLTexture
            public let presentationTime: CMTime
            // Hold the underlying CVPixelBuffer alive until the texture is consumed.
            let _retain: CVPixelBuffer
            /// The cropped copy's memory, when the reader crops.
            let cropped: (buffer: MTLBuffer, rowBytes: Int)?

            /// The frame's pixels in CPU memory (BGRA, top row first), as
            /// `texture` shows them.
            func withPixels<T>(_ body: (UnsafeRawPointer, _ width: Int, _ height: Int, _ rowBytes: Int) -> T) -> T? {
                if let cropped {
                    return body(cropped.buffer.contents(), texture.width, texture.height, cropped.rowBytes)
                }
                CVPixelBufferLockBaseAddress(_retain, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(_retain, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(_retain) else { return nil }
                return body(base, CVPixelBufferGetWidth(_retain), CVPixelBufferGetHeight(_retain),
                            CVPixelBufferGetBytesPerRow(_retain))
            }
        }

        public func nextFrame() -> Frame? {
            guard let sb = output.copyNextSampleBuffer(),
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
            let pts = firstFrameTime ?? CMSampleBufferGetPresentationTimeStamp(sb)
            firstFrameTime = nil
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            if let crop, let ring, crop.crops(width: w, height: h) {
                guard let slot = ring.copy(crop, from: pb) else { return nil }
                return Frame(texture: slot.texture, presentationTime: pts, _retain: pb,
                             cropped: (slot.buffer, slot.rowBytes))
            }

            var cvtex: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &cvtex
            )
            guard r == kCVReturnSuccess, let cvtex,
                  let mtl = CVMetalTextureGetTexture(cvtex) else {
                return nil
            }
            return Frame(texture: mtl, presentationTime: pts, _retain: pb, cropped: nil)
        }
    }

    /// True when frames need the track's rotation applied. The sequential
    /// reader hands back raw pixel buffers, so anything non-identity has to
    /// go through the (much slower) image-generator path to stay upright.
    public var needsPreferredTransform: Bool {
        videoTrack.preferredTransform != .identity
    }

    /// The frame size as displayed: the track's rotation applied, as the
    /// image-generator path decodes it.
    public var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: pixelSize).applying(videoTrack.preferredTransform)
        return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
    }

    /// Sequential reader positioned at a frame — the playback path.
    ///
    /// Decoding successive frames by seeking to each one re-decodes from the
    /// preceding keyframe every time: measured 47 ms/frame on a 1176×1764
    /// h264 clip versus 2.8 ms sequentially, which alone overruns a 24 fps
    /// frame budget.
    public func makeSequentialReader(startingAtFrame index: Int, crop: SourceCrop? = nil) throws -> SequentialReader {
        try makeSequentialReader(startFrame: index, crop: crop)
    }

    public func makeSequentialReader(crop: SourceCrop? = nil) throws -> SequentialReader {
        try makeSequentialReader(startFrame: 0, crop: crop)
    }

    private func makeSequentialReader(startFrame: Int, crop: SourceCrop?) throws -> SequentialReader {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw Error.readerSetup("\(error)") }
        // Must be set before reading starts (SequentialReader's init starts it).
        if startFrame > 0 {
            // The reader's first frame is the one on screen at this time.
            let start = decodeTime(ofFrame: startFrame)
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Error.readerSetup("reader cannot add output")
        }
        reader.add(output)
        return SequentialReader(reader: reader, output: output,
                                device: device, textureCache: textureCache, crop: crop,
                                firstFrameTime: startFrame > 0 ? time(ofFrame: startFrame) : nil)
    }
}
