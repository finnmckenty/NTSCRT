import Foundation

/// How big the preview renders, and how big it is shown.
public struct PreviewScaling: Equatable {
    /// Size the filter chain renders at.
    public let renderWidth: Int
    public let renderHeight: Int
    /// Size the picture occupies in the drawable at zoom 1, centered. With
    /// integer scale this is a whole multiple of the chain input; otherwise
    /// the largest size of the picture's shape that fits. Either way the rest
    /// of the drawable is letterbox, which a zoomed-in picture spills into.
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
                            margin: Int = 0,
                            minRenderMultiple: Int = PreviewScaler.minRenderMultiple,
                            maxLongEdge: Int = 4096) -> PreviewScaling {
        // The picture fits inside the drawable less `margin` on every side:
        // the drawable is the whole preview area (a zoomed-in picture fills
        // it), and at zoom 1 the picture keeps clear of its edges.
        let dw = max(1, drawableWidth - 2 * max(0, margin))
        let dh = max(1, drawableHeight - 2 * max(0, margin))

        // The largest size of the input's shape that fits.
        func fitSize() -> (width: Int, height: Int) {
            guard inputWidth > 0, inputHeight > 0 else { return (dw, dh) }
            let scale = min(Double(dw) / Double(inputWidth), Double(dh) / Double(inputHeight))
            return (min(dw, max(1, Int((Double(inputWidth) * scale).rounded()))),
                    min(dh, max(1, Int((Double(inputHeight) * scale).rounded()))))
        }

        // Render at the fitted size itself — only for an input we can't
        // reason about, or one too big to render at any multiple.
        func renderAtFit() -> PreviewScaling {
            let (fw, fh) = fitSize()
            let scale = min(1.0, Double(maxLongEdge) / Double(max(fw, fh)))
            return PreviewScaling(renderWidth: max(64, Int(Double(fw) * scale)),
                                  renderHeight: max(64, Int(Double(fh) * scale)),
                                  displayWidth: fw, displayHeight: fh,
                                  displayMultiple: 0, renderMultiple: 0)
        }
        guard inputWidth > 0, inputHeight > 0 else { return renderAtFit() }

        // Not integer-scaled: the image is fitted to the drawable — but it
        // is still rendered at the scanline floor and box-filtered down to
        // size. The look stays window-independent, and a fractional
        // rows-per-line ratio never reaches the shader: rendering straight
        // into the drawable gave some source lines 2 rows and others 3,
        // which banded.
        guard integerScale else {
            var rk = renderMultiple(forDisplay: 1, inputWidth: inputWidth, inputHeight: inputHeight,
                                    minRenderMultiple: minRenderMultiple, maxLongEdge: maxLongEdge)
            if rk > 1 && rk % 2 == 1 { rk -= 1 }     // odd multiples jitter glow shaders
            guard max(inputWidth, inputHeight) * rk <= maxLongEdge else { return renderAtFit() }
            let (fw, fh) = fitSize()
            return PreviewScaling(renderWidth: inputWidth * rk, renderHeight: inputHeight * rk,
                                  displayWidth: fw, displayHeight: fh,
                                  displayMultiple: 0, renderMultiple: rk)
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
            let (fitW, fitH) = fitSize()
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
