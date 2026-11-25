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

/// Decides the size the CRT shader renders at, and the preview's display
/// size.
///
/// 1. **One picture, however it is looked at.** CRT shaders draw scanlines
///    and masks in output pixels, so the multiple they render at *is* the
///    look — at 1 row per source line there is no room for a scanline at all
///    and the glow clips ~21% of the frame, and a mask's stripes are twice
///    as coarse against the picture at 3× as at 6×. So the shader renders at
///    one multiple that depends only on the picture going into it
///    (`renderMultiple`): the same in a small window and a large one, with
///    integer scale and without, and in every export
///    (`SupersampledPass`). The preview and an export are that one render
///    scaled to the window or the file by the same filter, so they look the
///    same. (Through 0.29.1 the preview rendered at 6× and up, by window
///    size, and an export straight at its own size: a 640-wide picture was
///    6× on screen and 3× in a 1920 file, and with Downscale off 2× and 1× —
///    a mask shader's export showed only stripes where the preview showed a
///    faint grid.)
/// 2. **Integer scale must snap.** The point of it is that every source line
///    gets the same whole number of screen rows, so the image steps between
///    sizes as the window grows and is letterboxed, rather than being scaled
///    to fit. The render and the display are both whole multiples of the
///    picture, so every source line and column is scaled alike, with no
///    pattern drifting across the picture.
public enum PreviewScaler {

    /// Fewest output rows per source line the chain may render at. 6 is where
    /// the glow shaders stop clipping (measured: k=1 clips 21% of the frame,
    /// k=2 6%, k=4 0.55%, k=6 none).
    public static let minRenderMultiple = 6

    /// The render's long edge is at least this, when the multiple allows
    /// it: a 1920 export (the default) of a small picture is then scaled
    /// down from the render, never up (256 wide renders at 8×, 160 at 12×).
    public static let minRenderLongEdge = 1920

    /// The largest render, on its long edge.
    public static let maxRenderLongEdge = 4096

    /// The picture the CRT shader is given, for one this size coming out of
    /// the Downscale (or straight from the source, with the Downscale off):
    /// itself, unless it is too large to render at two rows a line within
    /// the budget — then the largest of its shape that can be (2048 on its
    /// long edge). A shader drawing scanlines needs at least two rows for
    /// each line it is given. At one it draws none, only its mask; the
    /// aperture shader divides by the whole number of rows a line and is
    /// black below one — and at exactly one too, for line counts whose
    /// reciprocal rounds down (2544). `Pipeline.encode` scales the picture
    /// to this size on the way in.
    public static func shaderInput(width: Int, height: Int,
                                   maxLongEdge: Int = PreviewScaler.maxRenderLongEdge) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard width > 0, height > 0, longEdge * 2 > maxLongEdge else { return (width, height) }
        let scale = Double(maxLongEdge / 2) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// The multiple of the picture going into the CRT shader
    /// (`shaderInput`) that the shader renders at, for the preview and
    /// exports alike: the smallest even one that reaches both floors,
    /// stepped down to fit the texture budget (a 1024-wide picture renders
    /// at 4×, a 1920-wide one at 2×) — never under 2.
    /// Even, because at odd multiples the glow shaders' half-texel scanline
    /// offset lands beam boundaries on pixel edges and line spacing jitters.
    public static func renderMultiple(inputWidth: Int, inputHeight: Int,
                                      minRenderMultiple: Int = PreviewScaler.minRenderMultiple,
                                      maxLongEdge: Int = PreviewScaler.maxRenderLongEdge) -> Int {
        let longEdge = max(1, inputWidth, inputHeight)
        var m = max(2, minRenderMultiple, Int(ceil(Double(minRenderLongEdge) / Double(longEdge))))
        if m % 2 == 1 { m += 1 }
        while m > 2 && longEdge * m > maxLongEdge { m -= 2 }
        return m
    }

    public static func plan(inputWidth: Int, inputHeight: Int,
                            drawableWidth: Int, drawableHeight: Int,
                            integerScale: Bool,
                            margin: Int = 0,
                            minRenderMultiple: Int = PreviewScaler.minRenderMultiple,
                            maxLongEdge: Int = PreviewScaler.maxRenderLongEdge) -> PreviewScaling {
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

        // What the shader is given (the picture, or a smaller one when it
        // is too large to render), and the one render multiple for it,
        // whatever the window.
        let (inputWidth, inputHeight) = shaderInput(width: inputWidth, height: inputHeight, maxLongEdge: maxLongEdge)
        let rk = renderMultiple(inputWidth: inputWidth, inputHeight: inputHeight,
                                minRenderMultiple: minRenderMultiple, maxLongEdge: maxLongEdge)

        // Not integer-scaled: the image is fitted to the drawable, the
        // render box-filtered to that size. A fractional rows-per-line
        // ratio never reaches the shader: rendering straight into the
        // drawable gave some source lines 2 rows and others 3, which banded.
        guard integerScale else {
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
            return PreviewScaling(renderWidth: inputWidth * rk, renderHeight: inputHeight * rk,
                                  displayWidth: fitW, displayHeight: fitH,
                                  displayMultiple: 0, renderMultiple: rk)
        }

        return PreviewScaling(renderWidth: inputWidth * rk,
                              renderHeight: inputHeight * rk,
                              displayWidth: inputWidth * kDisplay,
                              displayHeight: inputHeight * kDisplay,
                              displayMultiple: kDisplay,
                              renderMultiple: rk)
    }
}
