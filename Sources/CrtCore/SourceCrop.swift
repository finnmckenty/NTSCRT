import Foundation
import Metal
import CoreVideo

/// A crop of the source picture to an aspect ratio, before anything else in
/// the chain sees it. At `scale` 1 it keeps as much of the picture as the
/// ratio allows, cutting the rest from one axis — the sides of a picture
/// that's too wide, the top and bottom of one that's too tall. A larger
/// scale zooms in: the crop shrinks inside that largest one (2: half its
/// width and height), with room to move both ways. `x` and `y` say where it
/// sits wherever there's room: 0 the left (top) edge, 1 the right (bottom),
/// 0.5 the middle.
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

    /// Zooming in stops at an eighth of the largest crop's width.
    public static let maxScale = 8.0

    public var ratio: Ratio
    public var x: Double
    public var y: Double
    public var scale: Double

    public init(ratio: Ratio, x: Double = 0.5, y: Double = 0.5, scale: Double = 1) {
        self.ratio = ratio
        self.x = x
        self.y = y
        self.scale = scale
    }

    /// The largest crop, placed `position` along whichever axis it cuts.
    public init(ratio: Ratio, position: Double) {
        self.init(ratio: ratio, x: position, y: position)
    }

    /// Which way the largest crop cuts a picture of this size: its width
    /// (it's too wide for the ratio), its height (too tall), or nothing
    /// (within half a percent of the ratio already).
    public enum Cut: Equatable, Sendable { case width, height, none }

    public func cut(width: Int, height: Int) -> Cut {
        guard width > 0, height > 0 else { return .none }
        let aspect = Double(width) / Double(height)
        if abs(aspect / ratio.value - 1) < 0.005 { return .none }
        return aspect > ratio.value ? .width : .height
    }

    /// The largest crop for the ratio in a picture of this size.
    public func largest(width: Int, height: Int) -> (width: Int, height: Int) {
        switch cut(width: width, height: height) {
        case .none: return (width, height)
        case .width: return (Self.even(Double(height) * ratio.value, within: width), height)
        case .height: return (width, Self.even(Double(width) / ratio.value, within: height))
        }
    }

    /// The crop in a picture of this size, in whole pixels: x, y, width,
    /// height. Sizes are even where the picture allows (video codecs and
    /// chroma like them), and the crop always lies inside the picture.
    public func rect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let base = largest(width: width, height: height)
        let s = min(Self.maxScale, max(1, scale))
        let w = s < 1.0001 ? base.width : Self.even(Double(base.width) / s, within: base.width)
        let h = s < 1.0001 ? base.height : Self.even(Double(base.height) / s, within: base.height)
        let px = min(1, max(0, x)), py = min(1, max(0, y))
        return (Int((Double(width - w) * px).rounded()), Int((Double(height - h) * py).rounded()), w, h)
    }

    /// Whether it takes anything away from a picture of this size.
    public func crops(width: Int, height: Int) -> Bool {
        let r = rect(width: width, height: height)
        return r.width != width || r.height != height
    }

    /// The crop that keeps the pixel rectangle (x, y, w) of a picture of
    /// this size — the inverse of `rect`, for dragging: the scale from the
    /// width (held to 1…maxScale), the place from the corner, held inside.
    public func placed(x left: Double, y top: Double, width w: Double, inWidth width: Int, height: Int) -> SourceCrop {
        let base = largest(width: width, height: height)
        let s = min(Self.maxScale, max(1, Double(base.width) / max(1, w)))
        var c = SourceCrop(ratio: ratio, x: x, y: y, scale: s)
        let r = c.rect(width: width, height: height)
        let roomX = Double(width - r.width), roomY = Double(height - r.height)
        if roomX > 0 { c.x = min(1, max(0, left / roomX)) }
        if roomY > 0 { c.y = min(1, max(0, top / roomY)) }
        return c
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
