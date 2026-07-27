import Foundation

/// How big the preview renders, and how big it is shown.
public struct PreviewScaling: Equatable {
    /// Size the filter chain renders at.
    public let renderWidth: Int
    public let renderHeight: Int
    /// Size the result occupies in the drawable. With integer scale this is a
    /// whole multiple of the chain input, letterboxed; otherwise it fills.
    public let displayWidth: Int
    public let displayHeight: Int
    /// display / chain input. 0 when not integer-scaled.
    public let displayMultiple: Int
    /// render / chain input.
    public let renderMultiple: Int

    /// True when the render has to be shrunk before it is shown.
    public var needsDownsample: Bool {
        renderWidth != displayWidth || renderHeight != displayHeight
    }
}

/// Decides the preview's render and display sizes.
///
/// Two requirements pull in opposite directions and this is where they are
/// reconciled:
///
/// 1. **The look must not depend on the window.** CRT shaders draw scanlines
///    and masks in output pixels, so the multiple they render at *is* the
///    look — at 1 row per source line there is no room for a scanline at all
///    and the glow clips ~21% of the frame. Hence a floor on the render
///    multiple, independent of window size.
/// 2. **Integer scale must snap.** The point of it is that every source line
///    gets the same whole number of screen rows, so the image steps between
///    sizes as the window grows and is letterboxed, rather than being scaled
///    to fit.
///
/// Both hold by rendering at a whole multiple that is itself a whole multiple
/// of the displayed one: the shader always gets enough rows, and the step down
/// to display size is an exact integer box filter (no resampling shimmer).
public enum PreviewScaler {

    /// Fewest output rows per source line the chain may render at. 6 is where
    /// the glow shaders stop clipping (measured: k=1 clips 21% of the frame,
    /// k=2 6%, k=4 0.55%, k=6 none).
    public static let minRenderMultiple = 6

    public static func plan(inputWidth: Int, inputHeight: Int,
                            drawableWidth: Int, drawableHeight: Int,
                            integerScale: Bool,
                            minRenderMultiple: Int = PreviewScaler.minRenderMultiple,
                            maxLongEdge: Int = 4096) -> PreviewScaling {
        let dw = max(1, drawableWidth), dh = max(1, drawableHeight)

        // Not integer-scaled: render at the drawable's own resolution (capped)
        // and fill it.
        guard integerScale, inputWidth > 0, inputHeight > 0 else {
            let scale = min(1.0, Double(maxLongEdge) / Double(max(dw, dh)))
            let rw = max(64, Int(Double(dw) * scale))
            let rh = max(64, Int(Double(dh) * scale))
            return PreviewScaling(renderWidth: rw, renderHeight: rh,
                                  displayWidth: dw, displayHeight: dh,
                                  displayMultiple: 0, renderMultiple: 0)
        }

        // Largest whole multiple of the chain input that fits the drawable.
        var kDisplay = max(1, min(dw / inputWidth, dh / inputHeight))
        // Prefer EVEN multiples: at odd ones the glow shaders' half-texel
        // scanline offset lands beam boundaries exactly on pixel edges and
        // float rounding jitters line spacing by a row (measured stddev 0.7
        // at k=9/11 vs 0.35 at k=10/12).
        if kDisplay > 1 && kDisplay % 2 == 1 { kDisplay -= 1 }

        // A window too small for even one full copy can't be integer-scaled;
        // fit instead so the image stays visible.
        if inputWidth * kDisplay > dw || inputHeight * kDisplay > dh {
            let scale = min(Double(dw) / Double(inputWidth), Double(dh) / Double(inputHeight))
            let fitW = max(1, Int((Double(inputWidth) * scale).rounded()))
            let fitH = max(1, Int((Double(inputHeight) * scale).rounded()))
            let rk = renderMultiple(forDisplay: 1, inputWidth: inputWidth,
                                    inputHeight: inputHeight,
                                    minRenderMultiple: minRenderMultiple,
                                    maxLongEdge: maxLongEdge)
            return PreviewScaling(renderWidth: inputWidth * rk, renderHeight: inputHeight * rk,
                                  displayWidth: fitW, displayHeight: fitH,
                                  displayMultiple: 0, renderMultiple: rk)
        }

        let kRender = renderMultiple(forDisplay: kDisplay,
                                     inputWidth: inputWidth, inputHeight: inputHeight,
                                     minRenderMultiple: minRenderMultiple,
                                     maxLongEdge: maxLongEdge)
        return PreviewScaling(renderWidth: inputWidth * kRender,
                              renderHeight: inputHeight * kRender,
                              displayWidth: inputWidth * kDisplay,
                              displayHeight: inputHeight * kDisplay,
                              displayMultiple: kDisplay,
                              renderMultiple: kRender)
    }

    /// Smallest whole multiple of `kDisplay` that reaches the render floor and
    /// still fits the texture budget. Keeping it a multiple of the displayed
    /// one makes the downsample an exact integer factor.
    private static func renderMultiple(forDisplay kDisplay: Int,
                                       inputWidth: Int, inputHeight: Int,
                                       minRenderMultiple: Int,
                                       maxLongEdge: Int) -> Int {
        let longEdge = max(inputWidth, inputHeight)
        var factor = max(1, Int(ceil(Double(minRenderMultiple) / Double(kDisplay))))
        while factor > 1 && longEdge * kDisplay * factor > maxLongEdge {
            factor -= 1
        }
        return kDisplay * factor
    }
}
