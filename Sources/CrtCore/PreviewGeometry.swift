import Foundation

/// The composite's drawable → texture mapping as a pure value, so the
/// invariants each past preview bug violated can be checked without a GPU:
///
/// - the letterbox offset is a whole number of pixels (a half-pixel center
///   put nearest samples on texel boundaries and duplicated ~150 rows);
/// - the framing reference is the *display* size whichever texture is
///   sampled, so zoom is continuous and toggling integer scale never
///   appears to change the zoom level;
/// - zoomed in, the full render is sampled rather than the display fit,
///   whose box filter averaged scanlines flat.
///
/// `PreviewCompositor` feeds exactly these numbers to the shader, and
/// `uv(px:py:)` is the shader's arithmetic.
public struct PreviewGeometry: Equatable {
    public let drawableWidth: Int
    public let drawableHeight: Int
    /// The displayed image's rect in drawable pixels: the plan's display size
    /// with integer scale (letterboxed), the drawable itself otherwise (fill).
    public let targetWidth: Int
    public let targetHeight: Int
    /// Whole-pixel letterbox offset.
    public let offsetX: Int
    public let offsetY: Int
    public let zoom: Float
    public let panX: Float
    public let panY: Float
    /// Zoomed in: bypass the display fit and sample the full render.
    public let samplesFullRender: Bool
    public let nearest: Bool

    /// Zoom values this close to 1 count as "fit".
    public static let zoomThreshold: Float = 1.001

    public static func make(plan: PreviewScaling,
                            drawableWidth: Int, drawableHeight: Int,
                            integerScale: Bool,
                            zoom: Float, panX: Float, panY: Float) -> PreviewGeometry {
        let z = max(1, zoom)
        let zoomed = z > zoomThreshold
        let fill = !integerScale
        let tw = fill ? drawableWidth : plan.displayWidth
        let th = fill ? drawableHeight : plan.displayHeight
        return PreviewGeometry(drawableWidth: drawableWidth, drawableHeight: drawableHeight,
                               targetWidth: tw, targetHeight: th,
                               offsetX: fill ? 0 : (drawableWidth - tw) / 2,
                               offsetY: fill ? 0 : (drawableHeight - th) / 2,
                               zoom: z, panX: panX, panY: panY,
                               samplesFullRender: zoomed,
                               // Pixel inspection wants raw texels; integer
                               // scale is exact multiples, so nearest is
                               // always right there too. Fill mode at fit is
                               // a fractional resample — linear.
                               nearest: zoomed || integerScale)
    }

    /// Normalized coordinate sampled for the drawable pixel (px, py) — the
    /// fragment shader's arithmetic — or nil where the letterbox shows.
    public func uv(px: Int, py: Int) -> SIMD2<Float>? {
        let fx = (Float(px) + 0.5) - Float(offsetX)
        let fy = (Float(py) + 0.5) - Float(offsetY)
        var u = fx / Float(targetWidth)
        var v = fy / Float(targetHeight)
        u = (u - 0.5) / zoom + 0.5 - panX
        v = (v - 0.5) / zoom + 0.5 - panY
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return SIMD2(u, v)
    }

    /// The drawable pixels that show the picture — the inverse of
    /// `uv(px:py:)` at the image's edges: a pixel shows it when its center
    /// samples inside. Zoomed in, the picture spills past the letterbox
    /// frame into the bars; it never reaches past the drawable. Export
    /// viewport copies exactly this.
    public var visiblePicture: (x: Int, y: Int, width: Int, height: Int)? {
        /// First and one-past-last pixel whose center lands in [0, 1].
        func span(offset: Int, size: Int, pan: Float, limit: Int) -> (Int, Int) {
            func center(_ u: Float) -> Float {
                Float(offset) + Float(size) * ((u - 0.5 + pan) * zoom + 0.5) - 0.5
            }
            return (max(0, Int(center(0).rounded(.up))),
                    min(limit, Int(center(1).rounded(.down)) + 1))
        }
        let (x0, x1) = span(offset: offsetX, size: targetWidth, pan: panX, limit: drawableWidth)
        let (y0, y1) = span(offset: offsetY, size: targetHeight, pan: panY, limit: drawableHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// Row of a `textureHeight`-row texture that nearest sampling picks for
    /// drawable row `py` (at the horizontal center).
    public func texelRow(py: Int, textureHeight: Int) -> Int? {
        guard let uv = uv(px: drawableWidth / 2, py: py) else { return nil }
        return min(textureHeight - 1, Int(uv.y * Float(textureHeight)))
    }
}
