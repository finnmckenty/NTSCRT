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

        let (duration, fps, size) = try await (
            asset.load(.duration),
            track.load(.nominalFrameRate),
            track.load(.naturalSize)
        )
        self.durationSeconds = CMTimeGetSeconds(duration)
        self.frameRate = fps > 0 ? fps : 30
        self.pixelSize = size
        self.totalFrames = max(1, Int((self.durationSeconds * Double(self.frameRate)).rounded()))

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

    /// Decode the frame nearest to `time` and return it as an MTLTexture.
    public func frame(at time: CMTime) async throws -> MTLTexture {
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
        return try cgImageToTexture(cgImage)
    }

    public func frame(atIndex index: Int) async throws -> MTLTexture {
        let t = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate.rounded()))
        return try await frame(at: t)
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

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput,
             device: MTLDevice, textureCache: CVMetalTextureCache) {
            self.reader = reader
            self.output = output
            self.device = device
            self.textureCache = textureCache
            reader.startReading()
        }

        public struct Frame {
            public let texture: MTLTexture
            public let presentationTime: CMTime
            // Hold the underlying CVPixelBuffer alive until the texture is consumed.
            let _retain: CVPixelBuffer
        }

        public func nextFrame() -> Frame? {
            guard let sb = output.copyNextSampleBuffer(),
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)

            var cvtex: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &cvtex
            )
            guard r == kCVReturnSuccess, let cvtex,
                  let mtl = CVMetalTextureGetTexture(cvtex) else {
                return nil
            }
            return Frame(texture: mtl, presentationTime: pts, _retain: pb)
        }
    }

    public func makeSequentialReader() throws -> SequentialReader {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw Error.readerSetup("\(error)") }
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
                                device: device, textureCache: textureCache)
    }
}
