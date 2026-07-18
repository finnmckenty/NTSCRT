import Foundation
import Metal

public enum DownscaleMethod: String, CaseIterable, Sendable {
    case nearest, bilinear, bicubic, lanczos, area
}

/// Downscales an input MTLTexture into a destination MTLTexture using a chosen
/// sampling kernel. The MSL source is compiled once at init time.
///
/// nearest and area run as a single compute dispatch. bilinear, bicubic and
/// lanczos are proper decimation filters: their kernel support scales with the
/// downscale ratio (a fixed-footprint interpolator skips source pixels when
/// minifying and aliases badly — the classic "bilinear downscale looks like
/// nearest" bug), and they run as two separable passes (horizontal into a
/// cached scratch texture, then vertical) so large ratios stay cheap.
///
/// Runs as Metal compute dispatches — destination must have `.shaderWrite`.
public final class Downscaler {

    private let device: MTLDevice
    private var pipelines: [String: MTLComputePipelineState] = [:]

    /// Intermediate (dstW × srcH) texture for the separable filters, reused
    /// while dimensions match. Guarded because the exporter and the preview
    /// can both reach the shared Downscaler.
    private var scratch: MTLTexture?
    private let scratchLock = NSLock()

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        for fname in ["downscale_nearest", "downscale_area",
                      "downscale_bilinear_h", "downscale_bilinear_v",
                      "downscale_bicubic_h", "downscale_bicubic_v",
                      "downscale_lanczos_h", "downscale_lanczos_v"] {
            guard let fn = library.makeFunction(name: fname) else {
                throw NSError(domain: "Downscaler", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "missing kernel \(fname)"])
            }
            pipelines[fname] = try device.makeComputePipelineState(function: fn)
        }
    }

    public func encode(into commandBuffer: MTLCommandBuffer,
                       source: MTLTexture,
                       destination: MTLTexture,
                       method: DownscaleMethod) {
        switch method {
        case .nearest, .area:
            dispatch(name: "downscale_\(method.rawValue)",
                     into: commandBuffer, src: source, dst: destination,
                     dims: (source.width, source.height, destination.width, destination.height),
                     gridW: destination.width, gridH: destination.height)

        case .bilinear, .bicubic, .lanczos:
            guard let mid = scratchTexture(width: destination.width,
                                           height: source.height,
                                           format: destination.pixelFormat) else { return }
            // Horizontal: (srcW × srcH) → (dstW × srcH)
            dispatch(name: "downscale_\(method.rawValue)_h",
                     into: commandBuffer, src: source, dst: mid,
                     dims: (source.width, source.height, destination.width, destination.height),
                     gridW: destination.width, gridH: source.height)
            // Vertical: (dstW × srcH) → (dstW × dstH)
            dispatch(name: "downscale_\(method.rawValue)_v",
                     into: commandBuffer, src: mid, dst: destination,
                     dims: (source.width, source.height, destination.width, destination.height),
                     gridW: destination.width, gridH: destination.height)
        }
    }

    private func dispatch(name: String,
                          into commandBuffer: MTLCommandBuffer,
                          src: MTLTexture, dst: MTLTexture,
                          dims: (Int, Int, Int, Int),
                          gridW: Int, gridH: Int) {
        guard let pipe = pipelines[name],
              let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipe)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        var d = SIMD4<UInt32>(UInt32(dims.0), UInt32(dims.1), UInt32(dims.2), UInt32(dims.3))
        enc.setBytes(&d, length: MemoryLayout<SIMD4<UInt32>>.size, index: 0)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (gridW + 7) / 8, height: (gridH + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func scratchTexture(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        scratchLock.lock()
        defer { scratchLock.unlock() }
        if let s = scratch, s.width == width, s.height == height, s.pixelFormat == format {
            return s
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        scratch = device.makeTexture(descriptor: d)
        return scratch
    }

    // MARK: - MSL source

    private static let metalSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Dims { uint sw, sh, dw, dh; };

    // ---------- nearest ----------
    kernel void downscale_nearest(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant Dims& d [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= d.dw || gid.y >= d.dh) return;
        float2 uv = (float2(gid) + 0.5) / float2(d.dw, d.dh);
        constexpr sampler s(filter::nearest, address::clamp_to_edge,
                            coord::normalized);
        dst.write(src.sample(s, uv), gid);
    }

    // ---------- weight functions ----------
    // t is in filter-space (source distance divided by the downscale ratio),
    // so each filter keeps its natural support: tent ±1, Mitchell ±2,
    // lanczos3 ±3 — scaled back up by the ratio in the passes below.
    inline float w_bilinear(float t) {
        return max(0.0, 1.0 - fabs(t));
    }

    inline float w_bicubic(float t) {   // Mitchell-Netravali B=C=1/3
        float x = fabs(t);
        const float B = 1.0/3.0, C = 1.0/3.0;
        float x2 = x*x, x3 = x2*x;
        if (x < 1.0)
            return ((12.0 - 9.0*B - 6.0*C) * x3 + (-18.0 + 12.0*B + 6.0*C) * x2 + (6.0 - 2.0*B)) * (1.0/6.0);
        if (x < 2.0)
            return ((-B - 6.0*C) * x3 + (6.0*B + 30.0*C) * x2 + (-12.0*B - 48.0*C) * x + (8.0*B + 24.0*C)) * (1.0/6.0);
        return 0.0;
    }

    inline float sinc(float x) {
        if (fabs(x) < 1e-6) return 1.0;
        float xp = x * M_PI_F;
        return sin(xp) / xp;
    }
    inline float w_lanczos(float t) {
        if (fabs(t) >= 3.0) return 0.0;
        return sinc(t) * sinc(t / 3.0);
    }

    // ---------- separable ratio-scaled passes ----------
    // Horizontal: (sw × sh) -> (dw × sh). Vertical: (dw × sh) -> (dw × dh).
    // scale = src/dst ratio (clamped >= 1 so magnification degrades to plain
    // interpolation); support = filter radius × scale.
    #define DEF_DOWNSCALE_1D(NAME, WFN, RADIUS) \\
    kernel void NAME##_h( \\
        texture2d<float, access::read>  src [[texture(0)]], \\
        texture2d<float, access::write> dst [[texture(1)]], \\
        constant Dims& d [[buffer(0)]], \\
        uint2 gid [[thread_position_in_grid]]) \\
    { \\
        if (gid.x >= d.dw || gid.y >= d.sh) return; \\
        float scale = max(1.0, float(d.sw) / float(d.dw)); \\
        float center = (float(gid.x) + 0.5) * float(d.sw) / float(d.dw) - 0.5; \\
        float support = float(RADIUS) * scale; \\
        int lo = int(ceil(center - support)); \\
        int hi = int(floor(center + support)); \\
        float4 acc = float4(0.0); \\
        float wsum = 0.0; \\
        for (int x = lo; x <= hi; x++) { \\
            float w = WFN((float(x) - center) / scale); \\
            int cx = clamp(x, 0, int(d.sw) - 1); \\
            acc += src.read(uint2(cx, gid.y)) * w; \\
            wsum += w; \\
        } \\
        dst.write(acc / max(wsum, 1e-6), gid); \\
    } \\
    kernel void NAME##_v( \\
        texture2d<float, access::read>  src [[texture(0)]], \\
        texture2d<float, access::write> dst [[texture(1)]], \\
        constant Dims& d [[buffer(0)]], \\
        uint2 gid [[thread_position_in_grid]]) \\
    { \\
        if (gid.x >= d.dw || gid.y >= d.dh) return; \\
        float scale = max(1.0, float(d.sh) / float(d.dh)); \\
        float center = (float(gid.y) + 0.5) * float(d.sh) / float(d.dh) - 0.5; \\
        float support = float(RADIUS) * scale; \\
        int lo = int(ceil(center - support)); \\
        int hi = int(floor(center + support)); \\
        float4 acc = float4(0.0); \\
        float wsum = 0.0; \\
        for (int y = lo; y <= hi; y++) { \\
            float w = WFN((float(y) - center) / scale); \\
            int cy = clamp(y, 0, int(d.sh) - 1); \\
            acc += src.read(uint2(gid.x, cy)) * w; \\
            wsum += w; \\
        } \\
        dst.write(acc / max(wsum, 1e-6), gid); \\
    }

    DEF_DOWNSCALE_1D(downscale_bilinear, w_bilinear, 1)
    DEF_DOWNSCALE_1D(downscale_bicubic,  w_bicubic,  2)
    DEF_DOWNSCALE_1D(downscale_lanczos,  w_lanczos,  3)

    // ---------- area (box average) ----------
    // Averages all source pixels covered by each destination pixel. The right
    // choice when the downscale ratio is large; produces smooth, anti-aliased
    // results without ringing.
    kernel void downscale_area(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant Dims& d [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= d.dw || gid.y >= d.dh) return;
        float sx0 = float(gid.x)     * float(d.sw) / float(d.dw);
        float sx1 = float(gid.x + 1) * float(d.sw) / float(d.dw);
        float sy0 = float(gid.y)     * float(d.sh) / float(d.dh);
        float sy1 = float(gid.y + 1) * float(d.sh) / float(d.dh);
        int x0 = int(floor(sx0)), x1 = int(ceil(sx1));
        int y0 = int(floor(sy0)), y1 = int(ceil(sy1));
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int y = y0; y < y1; y++) {
            float fy = clamp(min(float(y) + 1.0, sy1) - max(float(y), sy0), 0.0, 1.0);
            int cy = clamp(y, 0, int(d.sh) - 1);
            for (int x = x0; x < x1; x++) {
                float fx = clamp(min(float(x) + 1.0, sx1) - max(float(x), sx0), 0.0, 1.0);
                int cx = clamp(x, 0, int(d.sw) - 1);
                float w = fx * fy;
                acc += src.read(uint2(cx, cy)) * w;
                wsum += w;
            }
        }
        dst.write(acc / max(wsum, 1e-6), gid);
    }
    """
}
