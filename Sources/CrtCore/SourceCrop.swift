import Foundation
import Metal
import CoreVideo

/// A crop of the source picture to an aspect ratio, before anything else in
/// the chain sees it. The crop keeps as much of the picture as the ratio
/// allows and cuts the rest from one axis — the sides of a picture that's too
/// wide, the top and bottom of one that's too tall — with `position` saying
/// where along that axis it sits (0 the left or top edge, 1 the right or
/// bottom, 0.5 the middle).
public struct SourceCrop: Equatable, Sendable {
    public struct Ratio: Equatable, Hashable, Sendable {
        public let width: Int
        public let height: Int
        public init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
        }
        public var value: Double { Double(width) / Double(height) }
        /// "9:16".
        public var label: String { "\(width):\(height)" }
        public init?(label: String) {
            let parts = label.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            self.init(parts[0], parts[1])
        }
        public static let square = Ratio(1, 1)
    }

    /// The ratios on offer: square, then the portrait shapes, then the same
    /// shapes in landscape.
    public static let portrait = [Ratio(3, 4), Ratio(2, 3), Ratio(9, 16), Ratio(1, 2)]
    public static let landscape = [Ratio(4, 3), Ratio(3, 2), Ratio(16, 9), Ratio(2, 1)]

    public var ratio: Ratio
    public var position: Double

    public init(ratio: Ratio, position: Double = 0.5) {
        self.ratio = ratio
        self.position = position
    }

    /// Which way a picture of this size gets cut: its width (it's too wide
    /// for the ratio), its height (too tall), or nothing (within half a
    /// percent of the ratio already).
    public enum Cut: Equatable, Sendable { case width, height, none }

    public func cut(width: Int, height: Int) -> Cut {
        guard width > 0, height > 0 else { return .none }
        let aspect = Double(width) / Double(height)
        if abs(aspect / ratio.value - 1) < 0.005 { return .none }
        return aspect > ratio.value ? .width : .height
    }

    /// The crop in a picture of this size, in whole pixels: x, y, width,
    /// height. Sizes are even where the picture allows (video codecs and
    /// chroma like them), and the crop always lies inside the picture.
    public func rect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let p = min(1, max(0, position))
        switch cut(width: width, height: height) {
        case .none:
            return (0, 0, width, height)
        case .width:
            let w = Self.even(Double(height) * ratio.value, within: width)
            return (Int((Double(width - w) * p).rounded()), 0, w, height)
        case .height:
            let h = Self.even(Double(width) / ratio.value, within: height)
            return (0, Int((Double(height - h) * p).rounded()), width, h)
        }
    }

    private static func even(_ length: Double, within limit: Int) -> Int {
        let n = 2 * Int((length / 2).rounded())
        return max(1, min(limit, n))
    }

    // MARK: - applying it

    /// A copy of the crop's part of `texture`, on the GPU. Returns the
    /// texture itself when the crop cuts nothing.
    public func apply(to texture: MTLTexture, queue: MTLCommandQueue) throws -> MTLTexture {
        let r = rect(width: texture.width, height: texture.height)
        if r.width == texture.width && r.height == texture.height { return texture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                         width: r.width, height: r.height,
                                                         mipmapped: false)
        d.usage = texture.usage
        d.storageMode = texture.storageMode == .memoryless ? .private : texture.storageMode
        guard let out = queue.device.makeTexture(descriptor: d),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            throw NSError(domain: "SourceCrop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "couldn't make the cropped texture"])
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: r.x, y: r.y, z: 0),
                  sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                  to: out, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if out.storageMode == .managed { blit.synchronize(resource: out) }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return out
    }
}

/// Copies the crop's part of decoded video frames (BGRA pixel buffers) into
/// buffer-backed textures, reusing a small ring of them — for readers that
/// hand out cropped frames. A frame's texture stays valid until the ring
/// comes back round, `depth` frames later.
final class CropRing {
    struct Slot {
        let buffer: MTLBuffer
        let texture: MTLTexture
        let rowBytes: Int
    }

    private let device: MTLDevice
    private let depth: Int
    private var slots: [Slot] = []
    private var next = 0
    private var size = (width: 0, height: 0)

    init(device: MTLDevice, depth: Int) {
        self.device = device
        self.depth = max(2, depth)
    }

    /// The crop of `pixelBuffer`, or nil if it couldn't be copied.
    func copy(_ crop: SourceCrop, from pixelBuffer: CVPixelBuffer) -> Slot? {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let r = crop.rect(width: w, height: h)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let slot = slot(width: r.width, height: r.height) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<r.height {
            memcpy(slot.buffer.contents().advanced(by: y * slot.rowBytes),
                   base.advanced(by: (r.y + y) * srcRowBytes + r.x * 4), r.width * 4)
        }
        return slot
    }

    private func slot(width: Int, height: Int) -> Slot? {
        if size != (width, height) {
            slots.removeAll()
            next = 0
            size = (width, height)
        }
        if slots.count < depth {
            // Buffer-backed textures need 256-byte-aligned rows.
            let rowBytes = (width * 4 + 255) & ~255
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else {
                return nil
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                             height: height, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let texture = buffer.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes) else {
                return nil
            }
            let slot = Slot(buffer: buffer, texture: texture, rowBytes: rowBytes)
            slots.append(slot)
            return slot
        }
        let slot = slots[next]
        next = (next + 1) % depth
        return slot
    }
}
