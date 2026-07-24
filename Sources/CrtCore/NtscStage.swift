import Foundation
import Metal
import CrtAppBridge

/// CPU signal-degradation stage (ntsc-rs) between the downscaler and the
/// shader chain: GPU texture → CPU BGRA8 → ntsc-rs in place → back to a
/// CPU-visible texture the chain reads directly.
///
/// Storage-mode note (the Intel fix, PR #1): on discrete-GPU Macs the CPU
/// cannot coherently read a texture the GPU just wrote unless the texture is
/// `.managed` and a blit `synchronize(resource:)` runs after the GPU write —
/// otherwise `getBytes` returns stale zeros and the whole stage processes a
/// black frame. `synchronize` is *only* legal on managed resources (Metal
/// validation aborts on `.shared`), so we pick the storage mode per device:
/// `.shared` on unified memory (Apple silicon — identical to the original
/// behavior), `.managed` + synchronize on discrete GPUs. Managed textures
/// handle the CPU→GPU direction (`replace`) automatically.
///
/// The round trip runs synchronously (blit + waitUntilCompleted); at
/// chain-input sizes both the copy and the effect are a few milliseconds.
/// Instances are not thread-safe — keep each on one thread (main for the
/// preview, the export task for MP4), matching the single-queue rule of the
/// rest of the pipeline.
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

    /// Testing hook: CRT_FORCE_MANAGED=1 exercises the discrete-GPU path on
    /// unified-memory machines (managed storage is valid everywhere).
    static let forceManaged = ProcessInfo.processInfo.environment["CRT_FORCE_MANAGED"] != nil

    static func cpuStorageMode(for device: MTLDevice) -> MTLStorageMode {
        (device.hasUnifiedMemory && !forceManaged) ? .shared : .managed
    }

    private let filter: NTSCFilter
    private var roundTrip: MTLTexture?
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
        let storage = Self.cpuStorageMode(for: device)

        if roundTrip == nil || roundTrip!.width != w || roundTrip!.height != h
            || roundTrip!.pixelFormat != input.pixelFormat
            || roundTrip!.storageMode != storage {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = storage
            roundTrip = device.makeTexture(descriptor: d)
        }
        guard let tex = roundTrip else { throw Error.textureAlloc }

        // GPU → CPU-visible copy (synchronize required for managed).
        guard let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { throw Error.commandBuffer }
        blit.copy(from: input,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: tex,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if tex.storageMode == .managed {
            blit.synchronize(resource: tex)
        }
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
            tex.getBytes(raw.baseAddress!, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
            ok = filter.processBGRA8(raw.baseAddress!, width: UInt(w), height: UInt(h),
                                     rowBytes: UInt(rowBytes), frameIndex: frameIndex)
        }
        guard ok else { throw Error.processFailed }

        // CPU → GPU: replace() is coherent for both shared (unified memory)
        // and managed (Metal uploads the dirtied region) textures.
        tex.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
        return tex
    }
}
