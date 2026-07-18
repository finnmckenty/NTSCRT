import Foundation
import Metal
import CrtAppBridge

/// CPU signal-degradation stage (ntsc-rs) between the downscaler and the
/// shader chain: GPU texture → CPU BGRA8 → ntsc-rs in place → back to a
/// shared-storage texture the chain reads directly.
///
/// The round trip runs synchronously (blit + waitUntilCompleted); at
/// chain-input sizes (SD) both the copy and the effect are a few
/// milliseconds. Instances are not thread-safe — keep each on one thread
/// (main for the preview, the export task for MP4), matching the
/// single-queue rule of the rest of the pipeline.
public final class NtscStage {

    public enum Error: Swift.Error, LocalizedError {
        case commandBuffer
        case textureAlloc
        case processFailed
        public var errorDescription: String? {
            switch self {
            case .commandBuffer: return "ntsc: command buffer creation failed"
            case .textureAlloc: return "ntsc: staging texture allocation failed"
            case .processFailed: return "ntsc: frame processing failed"
            }
        }
    }

    private let filter: NTSCFilter
    private var sharedTex: MTLTexture?
    private var bytes: [UInt8] = []

    /// nil if the ntscrs-capi dylib hasn't been loaded (NTSCFilter.loadLibrary).
    public init?() {
        guard NTSCFilter.isLibraryLoaded(), let f = NTSCFilter() else { return nil }
        self.filter = f
    }

    /// Current settings in ntsc-rs preset JSON.
    public func settingsJSON() -> String? { filter.settingsJSON() }

    /// Replace settings from preset JSON (ntsc-rs GUI-compatible).
    public func setSettingsJSON(_ json: String) throws {
        try filter.setSettingsJSON(json)
    }

    /// Schema for building a settings UI (see ntscrs-capi descriptors).
    public static func descriptorsJSON() -> String? {
        NTSCFilter.settingsDescriptorsJSON()
    }

    /// Apply the effect to `input` and return a texture holding the result.
    /// The returned texture is owned by this stage and reused across calls —
    /// consume it before the next `process` call.
    public func process(input: MTLTexture,
                        frameIndex: Int,
                        device: MTLDevice,
                        queue: MTLCommandQueue) throws -> MTLTexture {
        let w = input.width, h = input.height

        if sharedTex == nil || sharedTex!.width != w || sharedTex!.height != h
            || sharedTex!.pixelFormat != input.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            sharedTex = device.makeTexture(descriptor: d)
        }
        guard let shared = sharedTex else { throw Error.textureAlloc }

        // GPU → CPU-visible copy.
        guard let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { throw Error.commandBuffer }
        blit.copy(from: input,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: shared,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // CPU: ntsc-rs in place.
        let rowBytes = w * 4
        let count = rowBytes * h
        if bytes.count != count { bytes = [UInt8](repeating: 0, count: count) }
        let region = MTLRegionMake2D(0, 0, w, h)
        var ok = false
        bytes.withUnsafeMutableBytes { raw in
            shared.getBytes(raw.baseAddress!, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
            ok = filter.processBGRA8(raw.baseAddress!, width: UInt(w), height: UInt(h),
                                     rowBytes: UInt(rowBytes), frameIndex: frameIndex)
        }
        guard ok else { throw Error.processFailed }

        shared.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
        return shared
    }
}
