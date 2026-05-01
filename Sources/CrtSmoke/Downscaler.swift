import Foundation
import Metal

enum DownscaleMethod: String, CaseIterable {
    case nearest, bilinear, bicubic, lanczos, area
}

/// Downscales an input MTLTexture into a destination MTLTexture using a chosen
/// sampling kernel. The MSL source is compiled once at init time.
///
/// Runs as a Metal compute dispatch — destination must have `.shaderWrite`.
final class Downscaler {

    private let device: MTLDevice
    private var pipelines: [DownscaleMethod: MTLComputePipelineState] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        for method in DownscaleMethod.allCases {
            let fname = "downscale_\(method.rawValue)"
            guard let fn = library.makeFunction(name: fname) else {
                throw NSError(domain: "Downscaler", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "missing kernel \(fname)"])
            }
            pipelines[method] = try device.makeComputePipelineState(function: fn)
        }
    }

    func encode(into commandBuffer: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                method: DownscaleMethod) {
        guard let pipe = pipelines[method] else { return }
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipe)
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)

        // Source/destination dimensions as a 4xUint constant buffer.
        var dims = SIMD4<UInt32>(UInt32(source.width), UInt32(source.height),
                                  UInt32(destination.width), UInt32(destination.height))
        enc.setBytes(&dims, length: MemoryLayout<SIMD4<UInt32>>.size, index: 0)

        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (destination.width + 7) / 8,
                             height: (destination.height + 7) / 8,
                             depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    // MARK: - MSL source

    private static let metalSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Dims { uint sw, sh, dw, dh; };

    inline float2 dst_to_src_uv(uint2 gid, constant Dims& d) {
        // sample at the centre of the destination pixel
        float2 dst = float2(gid) + 0.5;
        return float2(dst.x / float(d.dw), dst.y / float(d.dh));
    }

    // ---------- nearest ----------
    kernel void downscale_nearest(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant Dims& d [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= d.dw || gid.y >= d.dh) return;
        float2 uv = dst_to_src_uv(gid, d);
        constexpr sampler s(filter::nearest, address::clamp_to_edge,
                            coord::normalized);
        float4 c = src.sample(s, uv);
        dst.write(c, gid);
    }

    // ---------- bilinear ----------
    kernel void downscale_bilinear(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant Dims& d [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= d.dw || gid.y >= d.dh) return;
        float2 uv = dst_to_src_uv(gid, d);
        constexpr sampler s(filter::linear, address::clamp_to_edge,
                            coord::normalized);
        float4 c = src.sample(s, uv);
        dst.write(c, gid);
    }

    // ---------- bicubic (Mitchell-Netravali B=1/3 C=1/3) ----------
    inline float mitchell(float x) {
        x = fabs(x);
        const float B = 1.0/3.0, C = 1.0/3.0;
        float x2 = x*x, x3 = x2*x;
        if (x < 1.0)
            return ((12.0 - 9.0*B - 6.0*C) * x3 + (-18.0 + 12.0*B + 6.0*C) * x2 + (6.0 - 2.0*B)) * (1.0/6.0);
        if (x < 2.0)
            return ((-B - 6.0*C) * x3 + (6.0*B + 30.0*C) * x2 + (-12.0*B - 48.0*C) * x + (8.0*B + 24.0*C)) * (1.0/6.0);
        return 0.0;
    }
    kernel void downscale_bicubic(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant Dims& d [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= d.dw || gid.y >= d.dh) return;
        constexpr sampler s(filter::nearest, address::clamp_to_edge,
                            coord::pixel);
        float fx = (float(gid.x) + 0.5) * float(d.sw) / float(d.dw) - 0.5;
        float fy = (float(gid.y) + 0.5) * float(d.sh) / float(d.dh) - 0.5;
        int ix = int(floor(fx));
        int iy = int(floor(fy));
        float dx = fx - float(ix);
        float dy = fy - float(iy);
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int j = -1; j <= 2; j++) {
            float wy = mitchell(float(j) - dy);
            for (int i = -1; i <= 2; i++) {
                float wx = mitchell(float(i) - dx);
                int sx = clamp(ix + i, 0, int(d.sw) - 1);
                int sy = clamp(iy + j, 0, int(d.sh) - 1);
                float4 c = src.read(uint2(sx, sy));
                float w = wx * wy;
                acc += c * w;
                wsum += w;
            }
        }
        dst.write(acc / max(wsum, 1e-6), gid);
    }

    // ---------- lanczos3 ----------
    inline float sinc(float x) {
        if (fabs(x) < 1e-6) return 1.0;
        float xp = x * M_PI_F;
        return sin(xp) / xp;
    }
    inline float lanczos3(float x) {
        if (fabs(x) >= 3.0) return 0.0;
        return sinc(x) * sinc(x / 3.0);
    }
    kernel void downscale_lanczos(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write>  dst [[texture(1)]],
        constant Dims& d [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= d.dw || gid.y >= d.dh) return;
        float fx = (float(gid.x) + 0.5) * float(d.sw) / float(d.dw) - 0.5;
        float fy = (float(gid.y) + 0.5) * float(d.sh) / float(d.dh) - 0.5;
        int ix = int(floor(fx));
        int iy = int(floor(fy));
        float dx = fx - float(ix);
        float dy = fy - float(iy);
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int j = -2; j <= 3; j++) {
            float wy = lanczos3(float(j) - dy);
            for (int i = -2; i <= 3; i++) {
                float wx = lanczos3(float(i) - dx);
                int sx = clamp(ix + i, 0, int(d.sw) - 1);
                int sy = clamp(iy + j, 0, int(d.sh) - 1);
                float4 c = src.read(uint2(sx, sy));
                float w = wx * wy;
                acc += c * w;
                wsum += w;
            }
        }
        dst.write(acc / max(wsum, 1e-6), gid);
    }

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
