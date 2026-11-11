import Foundation
import Metal
import CrtAppBridge

/// CRT shaders draw their scanline and mask structure in *output* pixels.
/// When the output height isn't a whole multiple of the chain input height,
/// one source line covers a fractional number of rows (416 lines into 702
/// rows = 1.69), so some lines land on two pixels and some on one and the
/// phase drifts down the frame — visible as horizontal bands of scanlines.
/// The preview avoids it by rendering large and integer-scaled; exports
/// have to deal with it explicitly.
///
/// Two ways out, both offered:
///  - render at a whole multiple and integrate down (`supersampleFactor`),
///    which keeps the requested size;
///  - snap the requested size onto the grid (`snappedSize`), which keeps
///    the scanlines exact but changes the dimensions.
public enum ScanlineGrid {

    /// Multiple of the chain input to render at before downsampling to the
    /// requested size. 1 = render straight to the target.
    public static func supersampleFactor(inputHeight: Int, targetHeight: Int) -> Int {
        guard inputHeight > 0, targetHeight > 0 else { return 1 }
        // Already an exact multiple: the pattern is periodic, leave it alone
        // (this is what snapping produces, and supersampling would only
        // soften it).
        if targetHeight % inputHeight == 0 { return 1 }

        let rowsPerLine = Double(targetHeight) / Double(inputHeight)
        // At 3+ rows per source line the scanlines are already well
        // resolved; supersampling would only cost time.
        guard rowsPerLine < 3 else { return 1 }

        // Render 4 rows per source line — enough to resolve the scanline
        // profile — using an even multiple (odd ones put the beam boundary
        // exactly on a pixel edge in the glow shaders and reintroduce row
        // jitter). Step down if that would be disproportionate: a large
        // input with the downscale stage off (4K → a 540px GIF) is already
        // minifying and must not be blown up to 8640 rows.
        var k = 4
        while k > 2 && (k * inputHeight > 4 * targetHeight || k * inputHeight > 4096) {
            k -= 2
        }
        if k * inputHeight > 4 * targetHeight || k * inputHeight > 4096 { return 1 }
        return k
    }

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

/// Renders the chain at a whole multiple of its input and integrates the
/// result down to the requested size, so each output pixel averages the
/// true scanline profile instead of point-sampling an aliased one.
/// `make` returns nil when no supersampling is needed — callers then encode
/// straight into their target as before.
public final class SupersampledPass {
    private let superTarget: MTLTexture
    private let downscaler: Downscaler

    public let renderWidth: Int
    public let renderHeight: Int

    public static func make(device: MTLDevice,
                            chainInput: (width: Int, height: Int),
                            target: (width: Int, height: Int)) -> SupersampledPass? {
        let k = ScanlineGrid.supersampleFactor(inputHeight: chainInput.height,
                                               targetHeight: target.height)
        guard k > 1 else { return nil }
        // Whole multiples of the lines; the width follows the target's shape
        // (the picture's), which for one field isn't the lines' shape.
        let h = chainInput.height * k
        let w = Int((Double(target.width) * Double(h) / Double(target.height)).rounded())
        guard w > target.width, h > target.height,
              let tex = makeRenderTarget(device: device, width: w, height: h),
              let down = try? Downscaler(device: device) else { return nil }
        return SupersampledPass(superTarget: tex, downscaler: down)
    }

    private init(superTarget: MTLTexture, downscaler: Downscaler) {
        self.superTarget = superTarget
        self.downscaler = downscaler
        self.renderWidth = superTarget.width
        self.renderHeight = superTarget.height
    }

    /// Encode chain → oversized target → area-downsample into `output`.
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
