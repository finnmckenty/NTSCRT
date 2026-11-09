import Foundation
import Metal

/// What the Digital video stage needs for one frame.
public struct DigitalFrameInput {
    /// The frame within the clip, or the frame of a still's animation.
    public var frameIndex: Int
    /// The camera's resolution — the Downscale size.
    public var captureSize: (width: Int, height: Int)
    /// The clip's frame rate, or the timeline's for a still.
    public var sourceFPS: Double
    public var settings: DigitalSettings
    public var history: DigitalHistory?
    /// Earlier frames, for re-running from a keyframe; nil for a still.
    public var earlier: DigitalFrameVisitor?

    public init(frameIndex: Int, captureSize: (width: Int, height: Int), sourceFPS: Double,
                settings: DigitalSettings, history: DigitalHistory? = nil,
                earlier: DigitalFrameVisitor? = nil) {
        self.frameIndex = frameIndex
        self.captureSize = captureSize
        self.sourceFPS = sourceFPS
        self.settings = settings
        self.history = history
        self.earlier = earlier
    }

    /// The capture size for a picture: the Downscale's when it's on, else
    /// the picture's own (capped — the codec's cost grows with area).
    public static func captureSize(width: Int, height: Int,
                                   downscale: DownscaleSpec?) -> (width: Int, height: Int) {
        if let d = downscale { return (d.width, d.height) }
        return DigitalVideoRenderer.captureSize(width: width, height: height,
                                                captureWidth: min(width, maxUndownscaledWidth))
    }
    public static let maxUndownscaledWidth = 1280

    /// Run `renderer` on pixels in place.
    func apply(_ renderer: DigitalVideoRenderer, pixels: UnsafeMutableRawPointer,
               width: Int, height: Int, rowBytes: Int) {
        renderer.process(frame: frameIndex, pixels: pixels, width: width, height: height,
                         rowBytes: rowBytes, captureSize: captureSize, sourceFPS: sourceFPS,
                         settings: settings, history: history, earlier: earlier)
    }
}

/// The Digital video stage in an export: settings, and how they vary.
public struct DigitalExport {
    public var settings: DigitalSettings
    /// Keyframed settings by export frame, nil without keyframes.
    public var history: DigitalHistory?
    public init(settings: DigitalSettings, history: DigitalHistory? = nil) {
        self.settings = settings
        self.history = history
    }

    func input(frame: Int, width: Int, height: Int, downscale: DownscaleSpec?,
               sourceFPS: Double, earlier: DigitalFrameVisitor?) -> DigitalFrameInput {
        DigitalFrameInput(frameIndex: frame,
                          captureSize: DigitalFrameInput.captureSize(width: width, height: height,
                                                                     downscale: downscale),
                          sourceFPS: sourceFPS, settings: settings, history: history,
                          earlier: earlier)
    }
}

/// The stage on a GPU texture: read back, run the codec on the CPU, upload.
/// Used where the NTSC stage is off (with it on, the codec runs inside the
/// NTSC stage's own readback — see `NtscStage.process(prefilter:)`).
/// Same storage rules as NtscStage (managed + synchronize on discrete GPUs).
/// One per thread.
public final class DigitalStage {
    public let renderer = DigitalVideoRenderer()
    private var roundTrip: MTLTexture?
    private var cleanBytes: [UInt8] = []
    private var cleanVersion: Int?
    private var bytes: [UInt8] = []

    public init() {}

    /// The codec as an NtscStage prefilter.
    public func prefilter(_ input: DigitalFrameInput) -> NtscStage.Prefilter {
        let renderer = self.renderer
        return { pixels, w, h, rb in input.apply(renderer, pixels: pixels, width: w, height: h, rowBytes: rb) }
    }

    /// Apply the stage to `input`; the returned texture is reused by the
    /// next call. `inputVersion` as in NtscStage: unchanged contents skip
    /// the readback.
    public func process(input: MTLTexture, frame: DigitalFrameInput, inputVersion: Int?,
                        device: MTLDevice, queue: MTLCommandQueue) throws -> MTLTexture {
        let w = input.width, h = input.height
        let storage = NtscStage.cpuStorageMode(for: device)
        if roundTrip == nil || roundTrip!.width != w || roundTrip!.height != h
            || roundTrip!.pixelFormat != input.pixelFormat || roundTrip!.storageMode != storage {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = storage
            roundTrip = device.makeTexture(descriptor: d)
        }
        guard let tex = roundTrip else { throw NtscStage.Error.textureAlloc }
        let rowBytes = w * 4, count = rowBytes * h
        let region = MTLRegionMake2D(0, 0, w, h)
        if !(inputVersion != nil && inputVersion == cleanVersion && cleanBytes.count == count) {
            guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
                throw NtscStage.Error.commandBuffer
            }
            blit.copy(from: input, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: tex, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            if tex.storageMode == .managed { blit.synchronize(resource: tex) }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if cleanBytes.count != count { cleanBytes = [UInt8](repeating: 0, count: count) }
            cleanBytes.withUnsafeMutableBytes {
                tex.getBytes($0.baseAddress!, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
            }
            cleanVersion = inputVersion
        }
        bytes = cleanBytes
        bytes.withUnsafeMutableBytes {
            frame.apply(renderer, pixels: $0.baseAddress!, width: w, height: h, rowBytes: rowBytes)
        }
        tex.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
        return tex
    }
}

/// A clip's earlier frames for re-running the codec from a keyframe:
/// decoded in order with a reader of its own, restarted when asked to go
/// back. One per thread.
public final class DigitalClipFrames {
    private let source: VideoSource
    private let crop: SourceCrop?
    private var reader: VideoSource.SequentialReader?
    private var next = 0

    public init(source: VideoSource, crop: SourceCrop?) {
        self.source = source
        self.crop = crop
    }

    public func visit(_ frame: Int,
                      _ body: (UnsafeRawPointer, Int, Int, Int) -> Void) -> Bool {
        if reader == nil || frame < next {
            reader = try? source.makeSequentialReader(startingAtFrame: frame, crop: crop)
            next = frame
        }
        guard let reader else { return false }
        while next < frame {
            guard reader.nextFrame() != nil else { return false }
            next += 1
        }
        guard let f = reader.nextFrame() else { return false }
        next += 1
        return f.withPixels { body($0, $1, $2, $3) } != nil
    }

    public var visitor: DigitalFrameVisitor {
        { [self] frame, body in visit(frame, body) }
    }
}
