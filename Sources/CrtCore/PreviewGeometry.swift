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

    /// Row of a `textureHeight`-row texture that nearest sampling picks for
    /// drawable row `py` (at the horizontal center).
    public func texelRow(py: Int, textureHeight: Int) -> Int? {
        guard let uv = uv(px: drawableWidth / 2, py: py) else { return nil }
        return min(textureHeight - 1, Int(uv.y * Float(textureHeight)))
    }
}
