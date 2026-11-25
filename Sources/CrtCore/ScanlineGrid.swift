import Foundation
import Metal
import CrtAppBridge

/// CRT shaders draw their scanline and mask structure in *output* pixels,
/// so the size they render at is part of the look. Every export renders the
/// shader at the size the preview does (`PreviewScaler.renderMultiple`: a
/// whole even multiple of the picture going in, the same at any output
/// size) and integrates that down — or, for an output larger than the
/// render, up — to the size asked for (`SupersampledPass`), as the preview
/// does to fit its window. So an export looks like the preview, and a source
/// line never lands on a fractional number of rendered rows (416 lines
/// rendered straight into 702 rows gave some lines two rows and some one,
/// and the scanlines banded).
///
/// An output size that is itself a whole multiple of the picture
/// (`snappedSize`, the Export panel's "Snap size to scanline grid") scales
/// every source line and column alike.
public enum ScanlineGrid {

    /// What the shader actually sees: the downscale output when enabled,
    /// otherwise the source itself.
    public static func chainInputSize(width: Int, height: Int,
                                      downscale: DownscaleSpec?) -> (width: Int, height: Int) {
        if let d = downscale { return (d.width, d.height) }
        return (width, height)
    }

    /// Nearest output size whose height is a whole multiple of the chain
    /// input height, so every source line gets the same number of rows.
    /// Multiples of 2 and up are rounded to even (see above); 1× is kept as
    /// is, since at native size there's no scanline stretching to alias.
    /// `lineHeight` > 1 when each line stands for several picture rows (one
    /// field): the width follows the picture's shape, not the lines'.
    public static func snappedSize(inputWidth: Int, inputHeight: Int,
                                   targetHeight: Int, lineHeight: Int = 1) -> (width: Int, height: Int) {
        guard inputWidth > 0, inputHeight > 0, targetHeight > 0 else {
            return (inputWidth, inputHeight)
        }
        let exact = Double(targetHeight) / Double(inputHeight)
        var k = max(1, Int(exact.rounded()))
        if k >= 2 && k % 2 != 0 {
            // Pick whichever even multiple is closer to what was asked for.
            k = (exact - Double(k - 1)) < (Double(k + 1) - exact) ? k - 1 : k + 1
        }
        k = max(1, k)
        return (inputWidth * k / max(1, lineHeight), inputHeight * k)
    }
}

/// Renders the chain at the preview's size for this picture and scales the
/// result to the requested size with the filter the preview fits its window
/// with, so the export is the picture the preview shows.
/// `make` returns nil when the requested size is that size already —
/// callers then encode straight into their target.
public final class SupersampledPass {
    private let superTarget: MTLTexture
    private let downscaler: Downscaler

    public let renderWidth: Int
    public let renderHeight: Int

    /// The size the shader renders at for `chainInput` (width, scan lines):
    /// the preview's multiple of the picture. The picture's shape is the
    /// target's: with one field each line stands for two picture rows, and
    /// the render has whole lines either way. nil: nothing to render.
    public static func renderSize(chainInput: (width: Int, height: Int),
                                  target: (width: Int, height: Int)) -> (width: Int, height: Int)? {
        guard chainInput.width > 0, chainInput.height > 0, target.width > 0, target.height > 0 else { return nil }
        let pictureHeight = Double(chainInput.width) * Double(target.height) / Double(target.width)
        let lineHeight = max(1, Int((pictureHeight / Double(chainInput.height)).rounded()))
        // (The shader's picture: this one, or a smaller one when it is too
        // large to render — Pipeline.encode makes it.)
        let lines = PreviewScaler.shaderInput(width: chainInput.width, height: chainInput.height)
        let m = PreviewScaler.renderMultiple(inputWidth: lines.width, inputHeight: lines.height * lineHeight)
        return (lines.width * m, lines.height * lineHeight * m)
    }

    public static func make(device: MTLDevice,
                            chainInput: (width: Int, height: Int),
                            target: (width: Int, height: Int)) -> SupersampledPass? {
        guard let size = renderSize(chainInput: chainInput, target: target),
              size != target,
              let tex = makeRenderTarget(device: device, width: size.width, height: size.height),
              let down = try? Downscaler(device: device) else { return nil }
        return SupersampledPass(superTarget: tex, downscaler: down)
    }

    private init(superTarget: MTLTexture, downscaler: Downscaler) {
        self.superTarget = superTarget
        self.downscaler = downscaler
        self.renderWidth = superTarget.width
        self.renderHeight = superTarget.height
    }

    /// Encode chain → the render → area-resample into `output`.
    public func encode(into commandBuffer: MTLCommandBuffer,
                       pipeline: Pipeline,
                       chain: LRShaderChain,
                       inputTexture: MTLTexture,
                       outputTexture: MTLTexture,
                       downscale: DownscaleSpec?,
                       frameCount: Int) throws {
        try pipeline.encode(into: commandBuffer, chain: chain,
                            inputTexture: inputTexture, outputTexture: superTarget,
                            downscale: downscale, frameCount: frameCount)
        downscaler.encode(into: commandBuffer, source: superTarget,
                          destination: outputTexture, method: .area)
    }
}
