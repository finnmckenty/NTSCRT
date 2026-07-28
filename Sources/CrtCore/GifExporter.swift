import Foundation
import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CrtAppBridge

/// Encodes the CRT pipeline's output as an animated GIF.
///
/// GIF is a 256-colour, LZW-compressed format and our output is full-frame
/// animated noise — close to its worst case — so files run large and the
/// sensible sizes are small (measured: ~0.65–0.95 bytes per pixel per
/// frame). `estimatedBytes` exposes that so the UI can warn before an
/// export rather than after.
public final class GifExporter {

    public struct Settings {
        public var outputURL: URL
        /// GIF width; height follows the source aspect (both forced even).
        public var width: Int
        public var height: Int
        public var fps: Int
        public var downscale: DownscaleSpec?
        public var presetPath: String
        public init(outputURL: URL, width: Int, height: Int, fps: Int,
                    downscale: DownscaleSpec?, presetPath: String) {
            self.outputURL = outputURL
            self.width = width
            self.height = height
            self.fps = fps
            self.downscale = downscale
            self.presetPath = presetPath
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case destination
        case encodeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .destination: return "couldn't create the GIF file"
            case .encodeFailed(let s): return "GIF encode failed: \(s)"
            }
        }
    }

    /// Frame delays are stored as whole hundredths of a second, so the
    /// achievable rates sit on that grid: 12 fps really plays at 12.5, 24 at
    /// 25, 30 at 33.3. The floor of 2 (50 fps) is deliberate — many
    /// renderers clamp anything faster to a tenth of a second, which would
    /// play the animation at a crawl.
    public static func delayCentiseconds(fps: Int) -> Int {
        max(2, Int((100.0 / Double(max(1, fps))).rounded()))
    }

    public static func trueFPS(for fps: Int) -> Double {
        100.0 / Double(delayCentiseconds(fps: fps))
    }

    /// Rough size estimate. Measured on directly-rendered VHS output at
    /// 12 fps: 0.94 bytes/px/frame at 320px, 0.78 at 480, 0.66 at 640, 0.64
    /// at 960 (per-pixel cost falls as the noise spreads over more pixels).
    /// 0.8 splits that and errs high at the large end, where the warning
    /// matters. Clean, low-noise looks come in well under.
    ///
    /// Note: estimating from an already-encoded MP4 gives roughly half these
    /// figures — H.264 smooths exactly the high-frequency noise GIF can't
    /// compress, so it is not a valid proxy.
    public static func estimatedBytes(width: Int, height: Int, frames: Int) -> Int {
        Int(0.8 * Double(width * height * frames))
    }

    static func chainInputSize(source: MTLTexture, downscale: DownscaleSpec?) -> (width: Int, height: Int) {
        ScanlineGrid.chainInputSize(width: source.width, height: source.height, downscale: downscale)
    }

    static func chainInputSize(width: Int, height: Int,
                               downscale: DownscaleSpec?) -> (width: Int, height: Int) {
        ScanlineGrid.chainInputSize(width: width, height: height, downscale: downscale)
    }

    private let context: MetalContext
    private let pipeline: Pipeline
    public init(context: MetalContext) {
        self.context = context
        self.pipeline = Pipeline(context: context)
    }

    // MARK: - still → animated GIF

    /// Render `totalFrames` frames from one image, advancing the frame
    /// counter so tape noise and interlacing animate. `frameParams` supplies
    /// per-frame keyframe values, exactly as the MP4 path does.
    public func exportStill(source: MTLTexture,
                            totalFrames: Int,
                            paramValues: [String: Float],
                            settings: Settings,
                            ntscSettingsJSON: String? = nil,
                            frameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? = nil,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let ctx = try Context(exporter: self, settings: settings,
                              paramValues: paramValues, ntscSettingsJSON: ntscSettingsJSON,
                              frameCount: totalFrames,
                              chainInputSize: Self.chainInputSize(source: source,
                                                                 downscale: settings.downscale))
        try await Task.detached { [pipeline = self.pipeline] in
            for i in 0..<totalFrames {
                if let perFrame = frameParams?(i, totalFrames) {
                    if let shader = perFrame.shader {
                        for (n, v) in shader { try? ctx.chain.setParameter(n, value: v) }
                    }
                    if let json = perFrame.ntscJSON, let stage = ctx.ntscStage {
                        try stage.setSettingsJSON(json)
                    }
                }
                let image = try ctx.renderFrame(source: source, frameIndex: i + 1,
                                                pipeline: pipeline, sourceVersion: 0)
                ctx.add(image)
                progress(Double(i + 1) / Double(totalFrames))
            }
            try ctx.finalize()
        }.value
        progress(1.0)
    }

    // MARK: - video → animated GIF

    /// Decimate a video source down to `settings.fps` and encode the result.
    public func exportVideo(source: VideoSource,
                            paramValues: [String: Float],
                            settings: Settings,
                            ntscSettingsJSON: String? = nil,
                            frameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? = nil,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let sourceFPS = Double(max(1, source.frameRate))
        let step = max(1.0, sourceFPS / Double(max(1, settings.fps)))
        let sourceFrames = source.totalFrames
        let outFrames = max(1, Int((Double(sourceFrames) / step).rounded(.down)))

        let ctx = try Context(exporter: self, settings: settings,
                              paramValues: paramValues, ntscSettingsJSON: ntscSettingsJSON,
                              frameCount: outFrames,
                              chainInputSize: Self.chainInputSize(
                                  width: Int(source.pixelSize.width),
                                  height: Int(source.pixelSize.height),
                                  downscale: settings.downscale))
        let reader = try source.makeSequentialReader()
        try await Task.detached { [pipeline = self.pipeline] in
            var sourceIndex = 0
            var written = 0
            var nextWanted = 0.0
            while written < outFrames, let frame = reader.nextFrame() {
                // Keep the frame nearest each output timestamp.
                if Double(sourceIndex) >= nextWanted {
                    if let perFrame = frameParams?(written, outFrames) {
                        if let shader = perFrame.shader {
                            for (n, v) in shader { try? ctx.chain.setParameter(n, value: v) }
                        }
                        if let json = perFrame.ntscJSON, let stage = ctx.ntscStage {
                            try stage.setSettingsJSON(json)
                        }
                    }
                    let image = try ctx.renderFrame(source: frame.texture,
                                                    frameIndex: written + 1,
                                                    pipeline: pipeline,
                                                    sourceVersion: nil)   // new pixels each frame
                    ctx.add(image)
                    written += 1
                    nextWanted += step
                    progress(Double(written) / Double(outFrames))
                }
                sourceIndex += 1
            }
            try ctx.finalize()
        }.value
        progress(1.0)
    }

    // MARK: - shared encode context

    /// Owns the per-export GPU resources and the GIF destination. Frames are
    /// streamed in one at a time, so memory stays flat regardless of length.
    private final class Context: @unchecked Sendable {
        let chain: LRShaderChain
        let ntscStage: NtscStage?
        let target: MTLTexture
        /// Set when the requested size would alias the scanlines.
        let supersample: SupersampledPass?
        let staging: MTLTexture
        let queue: MTLCommandQueue
        let settings: Settings
        let destination: CGImageDestination
        let frameProperties: CFDictionary

        init(exporter: GifExporter, settings: Settings, paramValues: [String: Float],
             ntscSettingsJSON: String?, frameCount: Int,
             chainInputSize: (width: Int, height: Int)) throws {
            self.settings = settings
            self.queue = exporter.context.queue

            var stage: NtscStage? = nil
            if let json = ntscSettingsJSON {
                guard let s = NtscStage() else {
                    throw Error.encodeFailed("ntsc-rs stage unavailable (dylib not loaded)")
                }
                try s.setSettingsJSON(json)
                stage = s
            }
            self.ntscStage = stage

            self.chain = try LRShaderChain(presetPath: settings.presetPath,
                                           commandQueue: exporter.context.queue)
            for (n, v) in paramValues { try? chain.setParameter(n, value: v) }

            guard let target = makeRenderTarget(device: exporter.context.device,
                                                width: settings.width, height: settings.height),
                  let staging = makeStagingTexture(device: exporter.context.device,
                                                   width: settings.width, height: settings.height) else {
                throw Error.encodeFailed("texture allocation")
            }
            self.target = target
            self.staging = staging

            // Supersample when the shader would otherwise be squeezed into
            // too few rows per source line (see ScanlineGrid).
            self.supersample = SupersampledPass.make(device: exporter.context.device,
                                                     chainInput: chainInputSize,
                                                     target: (settings.width, settings.height))

            try? FileManager.default.removeItem(at: settings.outputURL)
            guard let dest = CGImageDestinationCreateWithURL(
                settings.outputURL as CFURL,
                UTType.gif.identifier as CFString,
                frameCount, nil) else {
                throw Error.destination
            }
            self.destination = dest
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)

            let delay = Double(GifExporter.delayCentiseconds(fps: settings.fps)) / 100.0
            self.frameProperties = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ] as CFDictionary
        }

        /// - Parameter sourceVersion: a constant for a still (one fixed image
        ///   for every frame, so the readback is reusable), nil for video —
        ///   passing a constant there would freeze frame one for the whole
        ///   clip.
        func renderFrame(source: MTLTexture, frameIndex: Int, pipeline: Pipeline,
                         sourceVersion: Int?) throws -> CGImage {
            guard let cb = queue.makeCommandBuffer() else {
                throw Error.encodeFailed("command buffer")
            }
            var input = source
            var downscale = settings.downscale
            if let stage = ntscStage {
                input = try pipeline.prepareChainInput(source: source, downscale: downscale,
                                                       ntsc: stage, frameCount: frameIndex,
                                                       sourceVersion: sourceVersion)
                downscale = nil
            }
            // Render big and integrate down, so the scanline pattern isn't
            // aliased into bands at GIF sizes.
            if let supersample {
                try supersample.encode(into: cb, pipeline: pipeline, chain: chain,
                                       inputTexture: input, outputTexture: target,
                                       downscale: downscale, frameCount: frameIndex)
            } else {
                try pipeline.encode(into: cb, chain: chain,
                                    inputTexture: input, outputTexture: target,
                                    downscale: downscale, frameCount: frameIndex)
            }

            guard let blit = cb.makeBlitCommandEncoder() else {
                throw Error.encodeFailed("blit encoder")
            }
            blit.copy(from: target,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: settings.width, height: settings.height, depth: 1),
                      to: staging,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            // Discrete GPUs need the explicit sync; illegal on .shared.
            if staging.storageMode == .managed {
                blit.synchronize(resource: staging)
            }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()

            // makeCGImage copies the pixels out, so reusing `staging` for the
            // next frame can't disturb one already handed to the encoder.
            return try makeCGImage(from: staging)
        }

        func add(_ image: CGImage) {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }

        func finalize() throws {
            if !CGImageDestinationFinalize(destination) {
                throw Error.encodeFailed("finalize")
            }
        }
    }
}
