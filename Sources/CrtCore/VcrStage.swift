import Foundation
import Metal

/// The VHS signal path the VCR simulation runs, at 8× the color subcarrier
/// (28.6 MHz, 1820 samples a line). Numbers are NTSC VHS SP: IEC 774-1 and
/// the parameters vhs-decode decodes real tapes with.
public enum VcrChannel {
    /// Samples per µs.
    public static let sampleRate = 8 * NTSCTiming.subcarrierMHz
    public static let samplesPerLine = 1820
    /// The tape is looked up once per segment of this many samples (0.56 µs,
    /// 3.2 µm of track) and interpolated between.
    public static let segment = 16
    public static var segments: Int { (samplesPerLine + segment - 1) / segment }

    /// Luminance FM: sync tip 3.4 MHz, peak white 4.4 MHz (140 IRE per MHz).
    public static let syncTipMHz = 3.4
    public static let mhzPerIRE = 1.0 / 140
    /// Color-under: 40 × the line rate, 629.37 kHz.
    public static let colorUnderMHz = 40 / NTSCTiming.line
    /// Color-under amplitude per unit of chroma (decoder scale), the FM
    /// carrier being 1: it is recorded well below the FM, which biases it.
    public static let chromaLevel: Float = 0.55
    /// Head and preamp noise per sample, against a carrier of 1: about 46 dB
    /// carrier-to-noise across the FM band, a good new tape's.
    public static let noise: Float = 0.006
    /// Main emphasis (IEC 774-1): a shelf with a 1.3 µs time constant and a
    /// gain of 5 (14 dB) — zero at 122 kHz, pole at 612 kHz.
    static let emphasisZeroMHz = 1 / (2 * Double.pi * 1.3)
    static let emphasisPoleMHz = 5 / (2 * Double.pi * 1.3)
    /// Recorded FM is clipped at these levels after emphasis (IRE).
    static let whiteClipIRE: Float = 226, darkClipIRE: Float = -82
    /// The FM band's analytic band-pass, and the demodulated luma low-pass.
    static let fmBandMHz = (1.3, 6.6)
    static let lumaMHz = 3.0
    static let chromaMHz = 0.55

    /// Spacing-loss filters: a bank over spacing 0–4 µm (square-root steps),
    /// each the spacing loss's Cauchy kernel (exp(−2π d/λ) in frequency)
    /// convolved with the head gap's aperture.
    static let levels = 64
    static let reach = 40
    static let maxSpacing: Float = 4

    /// 2π·d·f/v in nepers for d in µm and f in MHz.
    static let spacingNeper = 2 * Double.pi / TapeGeometry.writingSpeed

    /// Carrier-to-noise across the FM band (1.3–6.6 MHz) with a carrier of 1.
    public static var carrierToNoiseDB: Double {
        let band = (fmBandMHz.1 - fmBandMHz.0) / (sampleRate / 2)
        return 10 * log10(0.5 / (Double(noise * noise) * band))
    }

    /// The playback amplitude of a carrier at `mhz` after spacing `d` µm and
    /// a gap of `gap` µm (relative to an ideal head on new tape).
    public static func channelGain(mhz: Double, spacing d: Double, gap: Double) -> Double {
        let loss = exp(-spacingNeper * d * mhz)
        let x = Double.pi * gap * mhz / TapeGeometry.writingSpeed
        return loss * (x < 1e-6 ? 1 : abs(sin(x) / x))
    }

    /// Filter bank for one head: `levels` kernels of 2·reach+1 taps.
    static func bank(gap: Float) -> [Float] {
        let taps = 2 * reach + 1
        var out = [Float](repeating: 0, count: levels * taps)
        // Kernel widths in samples: the Cauchy half-width for spacing d is
        // d·(2π/v)/(2π) µs; the gap is g/v µs wide.
        let perUS = sampleRate
        let half = max(0.5, Double(gap) / TapeGeometry.writingSpeed * perUS / 2)
        for i in 0..<levels {
            let t = Double(i) / Double(levels - 1)
            let d = Double(maxSpacing) * t * t
            let c = max(1e-4, d / TapeGeometry.writingSpeed * perUS)
            for k in -reach...reach {
                let kd = Double(k)
                let w = (atan((kd + half) / c) - atan((kd - half) / c)) / (2 * Double.pi * half)
                out[i * taps + k + reach] = Float(w)
            }
        }
        return out
    }

    /// The FM band's complex (analytic) band-pass, 2·fmReach+1 taps, scaled
    /// so a carrier of amplitude A comes out as a phasor of magnitude A.
    static let fmReach = 47
    static func fmBandTaps() -> [SIMD2<Float>] {
        let (f1, f2) = fmBandMHz
        let n = 2 * fmReach + 1
        let beta = 6.0
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<30 { term *= (x / (2 * Double(k))) * (x / (2 * Double(k))); sum += term }
            return sum
        }
        var out: [SIMD2<Float>] = []
        for k in -fmReach...fmReach {
            let kd = Double(k)
            let w1 = 2 * Double.pi * f1 / sampleRate, w2 = 2 * Double.pi * f2 / sampleRate
            var re: Double, im: Double
            if k == 0 { re = (w2 - w1) / (2 * .pi); im = 0 } else {
                re = (sin(w2 * kd) - sin(w1 * kd)) / (2 * .pi * kd)
                im = (cos(w1 * kd) - cos(w2 * kd)) / (2 * .pi * kd)
            }
            let r = kd / Double(fmReach)
            let win = bessel0(beta * (1 - r * r).squareRoot()) / bessel0(beta)
            out.append(SIMD2(Float(2 * re * win), Float(2 * im * win)))
        }
        _ = n
        return out
    }

    /// Butterworth low-pass biquad (b0, b1, b2, a1, a2) at `mhz`.
    static func lowPass(_ mhz: Double) -> [Float] {
        let k = tan(Double.pi * mhz / sampleRate)
        let norm = 1 / (1 + 2.squareRoot() * k + k * k)
        let b0 = k * k * norm
        return [Float(b0), Float(2 * b0), Float(b0),
                Float(2 * (k * k - 1) * norm), Float((1 - 2.squareRoot() * k + k * k) * norm)]
    }

    /// First-order shelf (b0, b1, a1) with a zero and a pole, bilinear.
    static func shelf(zeroMHz: Double, poleMHz: Double) -> [Float] {
        let a = 2 * sampleRate / (2 * .pi * zeroMHz)
        let b = 2 * sampleRate / (2 * .pi * poleMHz)
        return [Float((1 + a) / (1 + b)), Float((1 - a) / (1 + b)), Float((1 - b) / (1 + b))]
    }
}

/// One active line as the VCR reads it: where on the tape, by which head,
/// in what state. Mirrors the GPU struct (8 × 4 bytes).
public struct VcrLine: Equatable {
    /// The track's start on the tape (see `TapePosition`).
    public var originBase: Int32
    public var originOffset: Float
    /// mm along that track where this line starts.
    public var along0: Float
    /// Head-to-tape spacing the head brings: worn tip and debris, µm.
    public var spacing: Float
    /// Its greasy film, µm (the head rides on whichever film is thicker).
    public var grease: Float
    /// Read efficiency × how much of its track the head is on.
    public var gain: Float
    public var head: UInt32
    var pad: Float = 0
}

/// What the VCR needs for one displayed field.
public struct VcrFieldPlan {
    public var lines: [VcrLine]
    public var tape: TapeParams
    public var deck: DeckParams
}

/// GPU half of the VCR: records each active line of the picture onto tape as
/// VHS does — luminance as FM after pre-emphasis and clipping, chroma
/// heterodyned down to 629 kHz under it — and plays it back: through the
/// tape (its coating, flaws and film, sampled across the head's width), the
/// head (spacing and gap losses, per head), noise, and the deck's
/// electronics (FM demodulation, de-emphasis, dropout detection and
/// compensation, color-under recovery with ACC, APC and a color killer).
/// Every failure is how that chain responds to what the tape and heads do:
/// sparkles are the FM threshold, streaks after bright edges are the lost
/// upper sideband, smeared color over noise is spacing loss sparing the
/// long color-under wavelength.
public final class VcrStage {
    private let device: MTLDevice
    private let pipes: [String: MTLComputePipelineState]
    private var buffers: [String: MTLBuffer] = [:]
    private var bankCache: (key: [Float], buffer: MTLBuffer)?
    private let fmTaps: MTLBuffer

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        var p: [String: MTLComputePipelineState] = [:]
        for name in ["vcr_record", "vcr_tape", "vcr_magnet", "vcr_play", "vcr_fmband",
                     "vcr_line", "vcr_acc", "vcr_out"] {
            guard let fn = library.makeFunction(name: name) else {
                throw NSError(domain: "VcrStage", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "missing kernel \(name)"])
            }
            p[name] = try device.makeComputePipelineState(function: fn)
        }
        pipes = p
        let taps = VcrChannel.fmBandTaps()
        guard let b = taps.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count,
                                                               options: .storageModeShared) }) else {
            throw NSError(domain: "VcrStage", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation"])
        }
        fmTaps = b
    }

    /// Mirrors `VcrU` in the shader: 4-byte scalars only.
    private struct Uniforms {
        var rows: UInt32, n: UInt32, segs: UInt32, width: UInt32
        var seed: UInt32, field: UInt32, doc: UInt32, fmReach: UInt32
        var levels: UInt32, reach: UInt32, linesPerField: UInt32, pad0: UInt32
        var usPerPixel: Float, dt: Float, lineUS: Float, lineLength: Float
        var pitch: Float, cosA: Float, sinA: Float, trackStart: Float
        var noise: Float, chromaLevel: Float, cuStep: Float, maxSpacing: Float
        var emB0: Float, emB1: Float, emA1: Float, whiteClip: Float
        var deB0: Float, deB1: Float, deA1: Float, darkClip: Float
        var lb0: Float, lb1: Float, lb2: Float, la1: Float
        var la2: Float, cb0: Float, cb1: Float, cb2: Float
        var ca1: Float, ca2: Float, docOn: Float, docOff: Float
        var wear: Float, dropouts: Float, scratches: Float, creases: Float
        var edge: Float, mold: Float, vaseline: Float, remanence: Float
        var roughness: Float, pinhole: Float, flake: Float, burstAmp: Float
    }

    private func buffer(_ name: String, bytes: Int) -> MTLBuffer? {
        if let b = buffers[name], b.length >= bytes { return b }
        let b = device.makeBuffer(length: max(16, bytes), options: .storageModePrivate)
        buffers[name] = b
        return b
    }

    private func bankBuffer(_ deck: DeckParams) -> MTLBuffer? {
        let key = [deck.gap(0), deck.gap(1)]
        if let c = bankCache, c.key == key { return c.buffer }
        let data = VcrChannel.bank(gap: key[0]) + VcrChannel.bank(gap: key[1])
        guard let b = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count,
                                                               options: .storageModeShared) })
        else { return nil }
        bankCache = (key, b)
        return b
    }

    /// Plays the picture `input` (one row per active line) from tape into
    /// `output` (same size).
    public func encode(into cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture,
                       plan: VcrFieldPlan, settings: GlitchSettings, raster: ReceiverRaster,
                       fieldIndex: UInt32) {
        let rows = min(plan.lines.count, input.height)
        guard rows > 0 else { return }
        let n = VcrChannel.samplesPerLine, segs = VcrChannel.segments
        let t = plan.tape
        let em = VcrChannel.shelf(zeroMHz: VcrChannel.emphasisZeroMHz, poleMHz: VcrChannel.emphasisPoleMHz)
        let de = VcrChannel.shelf(zeroMHz: VcrChannel.emphasisPoleMHz, poleMHz: VcrChannel.emphasisZeroMHz)
        let lp = VcrChannel.lowPass(VcrChannel.lumaMHz)
        let cp = VcrChannel.lowPass(VcrChannel.chromaMHz)
        var u = Uniforms(
            rows: UInt32(rows), n: UInt32(n), segs: UInt32(segs), width: UInt32(input.width),
            seed: t.seed, field: fieldIndex, doc: settings.flag("dropout_compensation") ? 1 : 0,
            fmReach: UInt32(VcrChannel.fmReach),
            levels: UInt32(VcrChannel.levels), reach: UInt32(VcrChannel.reach),
            linesPerField: UInt32(raster.totalLines), pad0: 0,
            usPerPixel: Float(NTSCTiming.activeLength / Double(input.width)),
            dt: Float(1 / VcrChannel.sampleRate), lineUS: Float(NTSCTiming.line),
            lineLength: Float(TapeGeometry.lineLength), pitch: Float(TapeGeometry.trackPitch),
            cosA: Float(cos(TapeGeometry.angle)), sinA: Float(sin(TapeGeometry.angle)),
            trackStart: Float(TapeGeometry.trackStart),
            noise: VcrChannel.noise, chromaLevel: VcrChannel.chromaLevel,
            cuStep: Float(2 * Double.pi * VcrChannel.colorUnderMHz / VcrChannel.sampleRate),
            maxSpacing: VcrChannel.maxSpacing,
            emB0: em[0], emB1: em[1], emA1: em[2], whiteClip: VcrChannel.whiteClipIRE,
            deB0: de[0], deB1: de[1], deA1: de[2], darkClip: VcrChannel.darkClipIRE,
            lb0: lp[0], lb1: lp[1], lb2: lp[2], la1: lp[3], la2: lp[4],
            cb0: cp[0], cb1: cp[1], cb2: cp[2], ca1: cp[3], ca2: cp[4],
            docOn: 0.1, docOff: 0.16,
            wear: t.wear, dropouts: t.dropouts, scratches: t.scratches, creases: t.creases,
            edge: t.edge, mold: t.mold, vaseline: t.vaseline, remanence: t.remanence,
            roughness: t.roughness, pinhole: t.pinholeChance, flake: t.flakeChance,
            burstAmp: Float(NTSCTiming.burstAmplitude))

        let samples = rows * n
        let lineBytes = rows * MemoryLayout<VcrLine>.stride
        guard let lineBuf = plan.lines.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: lineBytes, options: .storageModeShared) }),
              let bank = bankBuffer(plan.deck),
              let rf = buffer("rf", bytes: samples * 4),
              let seg = buffer("seg", bytes: rows * segs * 8),
              let mag = buffer("mag", bytes: samples * 8),
              let pb = buffer("pb", bytes: samples * 4),
              let z = buffer("z", bytes: samples * 8),
              let luma = buffer("luma", bytes: samples * 4),
              let chroma = buffer("chroma", bytes: samples * 8),
              let burst = buffer("burst", bytes: rows * 8),
              let color = buffer("color", bytes: rows * 16),
              let enc = cb.makeComputeCommandEncoder()
        else { return }

        func perRow(_ name: String) {
            let p = pipes[name]!
            enc.setComputePipelineState(p)
            enc.dispatchThreads(MTLSize(width: rows, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(32, p.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        func grid(_ name: String, _ w: Int, _ h: Int) {
            let p = pipes[name]!
            enc.setComputePipelineState(p)
            let tw = p.threadExecutionWidth
            let th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 4), depth: 1))
        }

        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setBuffer(lineBuf, offset: 0, index: 1)
        enc.setBuffer(rf, offset: 0, index: 2)
        enc.setBuffer(seg, offset: 0, index: 3)
        enc.setBuffer(mag, offset: 0, index: 4)
        enc.setBuffer(pb, offset: 0, index: 5)
        enc.setBuffer(z, offset: 0, index: 6)
        enc.setBuffer(luma, offset: 0, index: 7)
        enc.setBuffer(chroma, offset: 0, index: 8)
        enc.setBuffer(burst, offset: 0, index: 9)
        enc.setBuffer(color, offset: 0, index: 10)
        enc.setBuffer(bank, offset: 0, index: 11)
        enc.setBuffer(fmTaps, offset: 0, index: 12)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)

        perRow("vcr_record")
        grid("vcr_tape", segs, rows)
        grid("vcr_magnet", n, rows)
        grid("vcr_play", n, rows)
        grid("vcr_fmband", n, rows)
        perRow("vcr_line")
        let acc = pipes["vcr_acc"]!
        enc.setComputePipelineState(acc)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        grid("vcr_out", input.width, rows)
        enc.endEncoding()
    }

    /// The shader's tape map at `points` — for checking it against
    /// `TapeSurface.at`, which it must agree with.
    func probeTape(_ points: [TapePosition], _ t: TapeParams) throws -> [TapePoint] {
        let src = Self.metalSource + """

        struct ProbeIn { int base; float off; float y; float pad; };
        kernel void vcr_probe(constant VcrU& U [[buffer(0)]],
                              device const ProbeIn* pts [[buffer(1)]],
                              device float4* out [[buffer(2)]],
                              uint i [[thread_position_in_grid]])
        {
            TPos p; p.base = pts[i].base; p.off = pts[i].off; p.y = pts[i].y;
            TPt r = tapeAt(p, U);
            out[i] = float4(r.lift, r.film, r.out, 0.0);
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let pipe = try device.makeComputePipelineState(function: lib.makeFunction(name: "vcr_probe")!)
        var u = Uniforms(rows: 0, n: 0, segs: 0, width: 0, seed: t.seed, field: 0, doc: 0, fmReach: 0,
                         levels: 0, reach: 0, linesPerField: 0, pad0: 0, usPerPixel: 0, dt: 0, lineUS: 0,
                         lineLength: 0, pitch: 0, cosA: 0, sinA: 0, trackStart: 0, noise: 0,
                         chromaLevel: 0, cuStep: 0, maxSpacing: 0, emB0: 0, emB1: 0, emA1: 0,
                         whiteClip: 0, deB0: 0, deB1: 0, deA1: 0, darkClip: 0, lb0: 0, lb1: 0, lb2: 0,
                         la1: 0, la2: 0, cb0: 0, cb1: 0, cb2: 0, ca1: 0, ca2: 0, docOn: 0, docOff: 0,
                         wear: t.wear, dropouts: t.dropouts, scratches: t.scratches, creases: t.creases,
                         edge: t.edge, mold: t.mold, vaseline: t.vaseline, remanence: t.remanence,
                         roughness: t.roughness, pinhole: t.pinholeChance, flake: t.flakeChance,
                         burstAmp: 0)
        var raw: [Float] = []
        for p in points { raw += [Float(bitPattern: UInt32(bitPattern: p.base)), p.offset, p.y, 0] }
        let inBuf = device.makeBuffer(bytes: raw, length: raw.count * 4, options: .storageModeShared)!
        let outBuf = device.makeBuffer(length: points.count * 16, options: .storageModeShared)!
        let queue = device.makeCommandQueue()!
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipe)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setBuffer(inBuf, offset: 0, index: 1)
        enc.setBuffer(outBuf, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        let o = outBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: points.count)
        return (0..<points.count).map { TapePoint(lift: o[$0].x, film: o[$0].y, output: o[$0].z, shed: 0) }
    }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VcrU {
        uint rows, n, segs, width;
        uint seed, field, doc, fmReach;
        uint levels, reach, linesPerField, pad0;
        float usPerPixel, dt, lineUS, lineLength;
        float pitch, cosA, sinA, trackStart;
        float noise, chromaLevel, cuStep, maxSpacing;
        float emB0, emB1, emA1, whiteClip;
        float deB0, deB1, deA1, darkClip;
        float lb0, lb1, lb2, la1;
        float la2, cb0, cb1, cb2;
        float ca1, ca2, docOn, docOff;
        float wear, dropouts, scratches, creases;
        float edge, mold, vaseline, remanence;
        float roughness, pinhole, flake, burstAmp;
    };
    struct VcrLine {
        int originBase; float originOffset; float along0; float spacing;
        float grease; float gain; uint head; float pad;
    };

    constant float SYNC_END = 4.7;
    constant float BURST_S = 5.3;
    constant float BURST_E = 7.8;
    constant float ACT_S = 9.4;
    constant float ACT_L = 52.656;
    constant float TAPE_W = 12.65;
    constant float2 BURST_DIR = float2(0.5446390350, -0.8386705679);

    inline float3 rgb2yiq(float3 c) {
        return float3(0.299 * c.r + 0.587 * c.g + 0.114 * c.b,
                      0.596 * c.r - 0.274 * c.g - 0.322 * c.b,
                      0.211 * c.r - 0.523 * c.g + 0.312 * c.b);
    }
    inline float3 yiq2rgb(float3 y) {
        return float3(y.x + 0.9561706854 * y.y + 0.6214325663 * y.z,
                      y.x - 0.2726886023 * y.y - 0.6468132370 * y.z,
                      y.x - 1.1037440822 * y.y + 1.7006230947 * y.z);
    }

    // ---- hashing (identical to TapeSurface's) ----
    inline uint thash(uint a, uint b, uint c, uint d) {
        uint h = a * 0x8DA6B343u ^ b * 0xD8163841u ^ c * 0xCB1AB31Fu ^ d * 0x165667B1u;
        h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
        return h;
    }
    inline float tuni(uint a, uint b, int c, int d) {
        return (float(thash(a, b, as_type<uint>(c), as_type<uint>(d)) >> 8) + 0.5) * (1.0 / 16777216.0);
    }
    inline float gauss(uint a, uint b, int c, int d) {
        float u1 = tuni(a, b, c, d);
        float u2 = tuni(a ^ 0x5bd1e995u, b, c, d + 7);
        return sqrt(-2.0 * log(u1)) * cos(6.2831853 * u2);
    }
    inline float sm(float t) { return t * t * (3.0 - 2.0 * t); }
    inline float sstep(float e0, float e1, float x) {
        float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    // ---- the tape (TapeSurface.at, kept in step) ----
    struct TPos { int base; float off; float y; };
    struct Cell { int c; float f; };
    inline Cell tcell(TPos p, int q) {
        float whole = floor(p.off);
        int t = p.base + int(whole);
        int c = t / q;
        if (t % q != 0 && t < 0) c -= 1;
        Cell r; r.c = c; r.f = (float(t - c * q) + (p.off - whole)) / float(q);
        return r;
    }
    inline float tdx(TPos p, int c, int q, float frac) {
        return float(c * q - p.base) + frac * float(q) - p.off;
    }
    inline float noise1(uint s, uint k, int i, float f) {
        float a = tuni(s, k, i, 0), b = tuni(s, k, i + 1, 0);
        return a + (b - a) * sm(f);
    }
    inline float noise2(uint s, uint k, int i, float fi, int j, float fj) {
        float a = tuni(s, k, i, j), b = tuni(s, k, i + 1, j);
        float c = tuni(s, k, i, j + 1), d = tuni(s, k, i + 1, j + 1);
        float u = sm(fi), v = sm(fj);
        float lo = a + (b - a) * u, hi = c + (d - c) * u;
        return lo + (hi - lo) * v;
    }

    struct TPt { float lift; float film; float out; };
    inline TPt tapeAt(TPos p, constant VcrU& U) {
        uint s = U.seed;
        float y = p.y;
        float lift = U.roughness;
        float out = U.remanence;
        float film = 0.0;
        {
            Cell c = tcell(p, 5);
            float yy = y * 10.0;
            int cy = int(floor(yy));
            out *= 1.0 + (0.04 + 0.1 * U.wear) * (2.0 * noise2(s, 1u, c.c, c.f, cy, yy - float(cy)) - 1.0);
        }
        if (U.pinhole > 0.0) {
            Cell c = tcell(p, 1);
            int cy = int(floor(y * 10.0));
            for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
                int ci = c.c + i, cj = cy + j;
                if (tuni(s, 11u, ci, cj) >= U.pinhole) continue;
                float ddx = tdx(p, ci, 1, tuni(s, 12u, ci, cj)) * 0.1;
                float ddy = (float(cj) + tuni(s, 13u, ci, cj)) * 0.1 - y;
                float u = tuni(s, 14u, ci, cj);
                float r = 0.003 * pow(15.0, u * u);
                float d = sqrt(ddx * ddx + ddy * ddy);
                if (d < r) out *= sstep(r * 0.6, r, d);
            }
        }
        if (U.flake > 0.0) {
            Cell c = tcell(p, 10);
            int cy = int(floor(y));
            for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
                int ci = c.c + i, cj = cy + j;
                if (tuni(s, 21u, ci, cj) >= U.flake) continue;
                float ddx = tdx(p, ci, 10, tuni(s, 22u, ci, cj)) * 0.1;
                float ddy = float(cj) + tuni(s, 23u, ci, cj) - y;
                float u = tuni(s, 24u, ci, cj);
                float r = 0.04 * pow(8.0, u * u);
                float e = 0.6 + 0.8 * tuni(s, 25u, ci, cj);
                float d = sqrt((ddx / e) * (ddx / e) + (ddy * e) * (ddy * e));
                if (d < r * 1.5) out *= sstep(r * 0.8, r, d);
            }
        }
        if (U.scratches > 0.0) {
            int lane = int(floor(y * 20.0));
            Cell sx = tcell(p, 3000);
            for (int l = -1; l <= 1; l++) {
                int li = lane + l;
                if (tuni(s, 31u, li, sx.c) >= U.scratches * 0.06) continue;
                float a = tuni(s, 32u, li, sx.c), b = tuni(s, 33u, li, sx.c);
                if (sx.f < min(a, b) * 0.6 || sx.f > 0.4 + max(a, b) * 0.6) continue;
                float yc = (float(li) + 0.2 + 0.6 * tuni(s, 34u, li, sx.c)) * 0.05;
                float w = 0.006 + 0.045 * pow(tuni(s, 35u, li, sx.c), 2.0);
                if (fabs(y - yc) < w * 0.5) {
                    out *= 0.25 + 0.5 * tuni(s, 36u, li, sx.c);
                    lift += 0.04;
                }
            }
        }
        if (U.creases > 0.0) {
            Cell sx = tcell(p, 400);
            for (int k = -1; k <= 1; k++) {
                int ci = sx.c + k;
                if (tuni(s, 41u, ci, 0) >= U.creases * 0.9) continue;
                float off = tdx(p, ci, 400, tuni(s, 42u, ci, 0)) * 0.1;
                float slant = tan((tuni(s, 43u, ci, 0) - 0.5) * 0.7);
                bool fromBottom = tuni(s, 44u, ci, 0) < 0.5;
                float extent = TAPE_W * (0.25 + 0.75 * tuni(s, 45u, ci, 0));
                float yy = fromBottom ? y : TAPE_W - y;
                if (yy >= extent) continue;
                float reach = sstep(extent, extent * 0.8, yy);
                float w = 0.12 + 0.9 * tuni(s, 46u, ci, 0);
                float peak = (0.5 + 3.5 * pow(tuni(s, 47u, ci, 0), 1.5)) * (0.4 + 0.6 * U.creases);
                float dd = (off + yy * slant) / w;
                if (fabs(dd) >= 4.0) continue;
                float profile = exp(-dd * dd) * (0.75 + 0.25 * cos(dd * 9.0));
                lift += peak * profile * reach;
                out *= 1.0 - 0.3 * profile * reach;
            }
        }
        if (U.edge > 0.0) {
            for (int side = 0; side < 2; side++) {
                uint k = uint(51 + side * 4);
                float yy = side == 0 ? y : TAPE_W - y;
                Cell c60 = tcell(p, 600);
                float stretch = noise1(s, k, c60.c, c60.f);
                float damaged = sstep(U.edge * 0.85, U.edge * 0.85 - 0.1, stretch);
                if (damaged <= 0.0) continue;
                Cell c20 = tcell(p, 200);
                float reach = 0.3 + 1.9 * U.edge * (0.5 + 0.5 * noise1(s, k + 1u, c20.c, c20.f));
                if (yy >= reach) continue;
                Cell c1 = tcell(p, 12);
                float crinkle = noise1(s, k + 2u, c1.c, c1.f);
                lift += damaged * U.edge * (1.0 + 2.5 * crinkle * crinkle) * pow(1.0 - yy / reach, 0.7);
            }
        }
        if (U.mold > 0.0) {
            Cell c = tcell(p, 40);
            int cy = int(floor(y / 4.0));
            for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
                int ci = c.c + i, cj = cy + j;
                float ycen = (float(cj) + tuni(s, 63u, ci, cj)) * 4.0;
                if (ycen <= -1.0 || ycen >= TAPE_W + 1.0) continue;
                float edgeNear = 1.0 - min(1.0, min(fabs(ycen), fabs(TAPE_W - ycen)) / 6.3);
                if (tuni(s, 61u, ci, cj) >= min(0.95, U.mold * (0.3 + 1.3 * edgeNear))) continue;
                float ddx = tdx(p, ci, 40, tuni(s, 62u, ci, cj)) * 0.1;
                float ddy = ycen - y;
                float d = sqrt(ddx * ddx + ddy * ddy);
                float big = (0.35 + 2.0 * pow(tuni(s, 64u, ci, cj), 1.3)) * (0.6 + 0.4 * U.mold);
                if (d >= big * 1.4) continue;
                float turn = (atan2(ddy, ddx) / 6.2831853 + 0.5) * 6.0;
                int ti = int(floor(turn));
                float a0 = tuni(s, 65u, ci * 7 + (ti % 6), cj), a1 = tuni(s, 65u, ci * 7 + ((ti + 1) % 6), cj);
                float rr = big * (0.7 + 0.6 * (a0 + (a1 - a0) * sm(turn - float(ti))));
                float dens = 1.0 - sstep(rr * 0.35, rr, d);
                if (dens <= 0.0) continue;
                Cell f3 = tcell(p, 3);
                float fy3 = y * 0.33 * 10.0;
                int gy = int(floor(fy3));
                dens *= 0.55 + 0.45 * noise2(s, 66u, f3.c, f3.f, gy, fy3 - float(gy));
                lift += dens * (0.5 + 2.5 * U.mold);
                out *= 1.0 - 0.55 * dens;
            }
        }
        if (U.vaseline > 0.0) {
            Cell sx = tcell(p, 600);
            if (tuni(s, 71u, sx.c, 0) < 0.2 + 0.8 * U.vaseline) {
                float a = 0.4 * tuni(s, 72u, sx.c, 0);
                float b = 0.6 + 0.4 * tuni(s, 73u, sx.c, 0);
                float taper = sstep(a, a + 0.05, sx.f) * sstep(b, b - 0.05, sx.f);
                if (taper > 0.0) {
                    Cell c8 = tcell(p, 80);
                    float yy = y * 5.0;
                    int cy = int(floor(yy));
                    float streak = pow(noise2(s, 74u, c8.c, c8.f, cy, yy - float(cy)), 1.5);
                    film = U.vaseline * 1.5 * (0.3 + 0.7 * streak) * taper;
                }
            }
        }
        TPt r; r.lift = lift; r.film = film; r.out = max(0.0, out);
        return r;
    }

    // ---- 1: record each line (one thread per row, along the line) ----
    kernel void vcr_record(constant VcrU& U [[buffer(0)]],
                           device float* rf [[buffer(2)]],
                           texture2d<float, access::read> src [[texture(0)]],
                           uint y [[thread_position_in_grid]])
    {
        if (y >= U.rows) return;
        int w = int(U.width);
        float phase = 6.2831853 * tuni(U.seed ^ 0xA5A5u, U.field, int(y), 1);
        float xPrev = 0.0, ePrev = 0.0;
        for (uint i = 0; i < U.n; i++) {
            float u = (float(i) + 0.5) * U.dt;
            float ire = 0.0;
            float2 c = float2(0.0);
            if (u < SYNC_END) ire = -40.0;
            else if (u < ACT_S) {
                if (u >= BURST_S && u < BURST_E) c = BURST_DIR * U.burstAmp;
            } else if (u < ACT_S + ACT_L) {
                float xs = (u - ACT_S) / U.usPerPixel - 0.5;
                float x0 = floor(xs);
                float f = xs - x0;
                int ix = int(x0);
                float3 a = src.read(uint2(uint(clamp(ix, 0, w - 1)), y)).rgb;
                float3 b = src.read(uint2(uint(clamp(ix + 1, 0, w - 1)), y)).rgb;
                float3 q = rgb2yiq(mix(a, b, f));
                ire = 7.5 + 92.5 * q.x;
                c = q.yz;
            }
            // Main emphasis, then the white and dark clips.
            float e = U.emB0 * ire + U.emB1 * xPrev - U.emA1 * ePrev;
            xPrev = ire; ePrev = e;
            float ec = clamp(e, U.darkClip, U.whiteClip);
            float mhz = 3.4 + (ec + 40.0) / 140.0;
            phase += 6.2831853 * mhz * U.dt;
            phase -= 6.2831853 * floor(phase / 6.2831853);
            float a = U.cuStep * float(i);
            float under = U.chromaLevel * (c.x * cos(a) - c.y * sin(a));
            rf[y * U.n + i] = cos(phase) + under;
        }
    }

    // ---- 2: the tape under each segment, across the head's width ----
    kernel void vcr_tape(constant VcrU& U [[buffer(0)]],
                         device const VcrLine* lines [[buffer(1)]],
                         device float2* seg [[buffer(3)]],
                         uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= U.segs || gid.y >= U.rows) return;
        VcrLine L = lines[gid.y];
        float u = (float(gid.x) + 0.5) * 16.0 * U.dt;
        float along = L.along0 + u / U.lineUS * U.lineLength;
        float lift = 0.0, film = 0.0, out = 0.0;
        for (int k = 0; k < 2; k++) {
            float across = (k == 0 ? -0.25 : 0.25) * U.pitch;
            TPos p;
            p.base = L.originBase;
            p.off = L.originOffset + (along * U.cosA - across * U.sinA) * 10.0;
            p.y = U.trackStart + along * U.sinA + across * U.cosA;
            TPt t = tapeAt(p, U);
            lift += t.lift; film += t.film; out += t.out;
        }
        lift *= 0.5; film *= 0.5; out *= 0.5;
        float d = lift + L.spacing + max(film, L.grease);
        seg[gid.y * U.segs + gid.x] = float2(d, out * L.gain);
    }

    // ---- 3: what is magnetized under the head, and how far away ----
    kernel void vcr_magnet(constant VcrU& U [[buffer(0)]],
                           device const float* rf [[buffer(2)]],
                           device const float2* seg [[buffer(3)]],
                           device float2* mag [[buffer(4)]],
                           uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= U.n || gid.y >= U.rows) return;
        float sf = (float(gid.x) + 0.5) / 16.0 - 0.5;
        int i0 = clamp(int(floor(sf)), 0, int(U.segs) - 1);
        int i1 = min(i0 + 1, int(U.segs) - 1);
        float t = clamp(sf - float(i0), 0.0, 1.0);
        float2 a = seg[gid.y * U.segs + i0], b = seg[gid.y * U.segs + i1];
        float2 v = mix(a, b, t);
        uint k = gid.y * U.n + gid.x;
        mag[k] = float2(rf[k] * v.y, v.x);
    }

    // ---- 4: the head reads it: spacing and gap losses, plus noise ----
    kernel void vcr_play(constant VcrU& U [[buffer(0)]],
                         device const VcrLine* lines [[buffer(1)]],
                         device const float2* mag [[buffer(4)]],
                         device float* pb [[buffer(5)]],
                         device const float* bank [[buffer(11)]],
                         uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= U.n || gid.y >= U.rows) return;
        uint row = gid.y * U.n;
        int i = int(gid.x);
        float d = mag[row + uint(i)].y;
        float lv = sqrt(clamp(d / U.maxSpacing, 0.0, 1.0)) * float(U.levels - 1);
        int l0 = min(int(floor(lv)), int(U.levels) - 2);
        float t = lv - float(l0);
        int R = int(U.reach);
        uint taps = uint(2 * R + 1);
        device const float* k0 = bank + (lines[gid.y].head * U.levels + uint(l0)) * taps;
        device const float* k1 = k0 + taps;
        float acc = 0.0;
        int last = int(U.n) - 1;
        for (int k = -R; k <= R; k++) {
            int j = clamp(i - k, 0, last);
            float w = mix(k0[k + R], k1[k + R], t);
            acc += w * mag[row + uint(j)].x;
        }
        acc += U.noise * gauss(U.seed ^ 0x51u, U.field, i, int(gid.y));
        pb[row + uint(i)] = acc;
    }

    // ---- 5: the FM band as an analytic signal ----
    kernel void vcr_fmband(constant VcrU& U [[buffer(0)]],
                           device const float* pb [[buffer(5)]],
                           device float2* z [[buffer(6)]],
                           device const float2* taps [[buffer(12)]],
                           uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= U.n || gid.y >= U.rows) return;
        uint row = gid.y * U.n;
        int i = int(gid.x);
        int R = int(U.fmReach);
        int last = int(U.n) - 1;
        float2 acc = float2(0.0);
        for (int k = -R; k <= R; k++) {
            int j = clamp(i - k, 0, last);
            acc += taps[k + R] * pb[row + uint(j)];
        }
        z[row + uint(i)] = acc;
    }

    inline float biquad(thread float4& s, float x, float b0, float b1, float b2, float a1, float a2) {
        // s = (x1, x2, y1, y2)
        float y = b0 * x + b1 * s.x + b2 * s.y - a1 * s.z - a2 * s.w;
        s = float4(x, s.x, y, s.z);
        return y;
    }

    // ---- 6: the deck's electronics, along each line ----
    // FM demodulation, luma low-pass (zero-phase) and de-emphasis, the
    // dropout detector; color-under brought back to baseband (zero-phase
    // low-pass) and its burst measured.
    kernel void vcr_line(constant VcrU& U [[buffer(0)]],
                         device const float* pb [[buffer(5)]],
                         device const float2* z [[buffer(6)]],
                         device float* luma [[buffer(7)]],
                         device float2* chroma [[buffer(8)]],
                         device float2* burst [[buffer(9)]],
                         uint y [[thread_position_in_grid]])
    {
        if (y >= U.rows) return;
        uint row = y * U.n;
        uint N = U.n;
        // Instantaneous frequency → IRE; the dropout detector on the
        // envelope (sign bit of luma marks a flagged sample later).
        float2 prev = z[row];
        float env = length(prev);
        bool flagged = false;
        int hold = 0;
        for (uint i = 0; i < N; i++) {
            float2 c = z[row + i];
            float dphi = atan2(prev.x * c.y - prev.y * c.x, prev.x * c.x + prev.y * c.y);
            prev = c;
            float mhz = clamp(dphi / (6.2831853 * U.dt), 1.0, 7.5);
            luma[row + i] = (mhz - 3.4) * 140.0 - 40.0;
            env += 0.12 * (length(c) - env);
            if (flagged) {
                if (env > U.docOff) { hold -= 1; if (hold <= 0) flagged = false; }
                else hold = 14;
            } else if (env < U.docOn) { flagged = true; hold = 14; }
            chroma[row + i] = float2(flagged ? 1.0 : 0.0, 0.0);
        }
        // Luma: zero-phase low-pass (forward, then backward), de-emphasis.
        float4 s = float4(luma[row], luma[row], luma[row], luma[row]);
        for (uint i = 0; i < N; i++) luma[row + i] = biquad(s, luma[row + i], U.lb0, U.lb1, U.lb2, U.la1, U.la2);
        s = float4(luma[row + N - 1]);
        for (int i = int(N) - 1; i >= 0; i--) luma[row + uint(i)] = biquad(s, luma[row + uint(i)], U.lb0, U.lb1, U.lb2, U.la1, U.la2);
        float xp = luma[row], yp = luma[row];
        for (uint i = 0; i < N; i++) {
            float x = luma[row + i];
            float v = U.deB0 * x + U.deB1 * xp - U.deA1 * yp;
            xp = x; yp = v;
            // Flagged samples are stored as v + 10000 (decoded in vcr_out).
            luma[row + i] = chroma[row + i].x > 0.5 ? v + 10000.0 : v;
        }
        // Color-under: mix down, zero-phase low-pass twice (8th order).
        for (uint i = 0; i < N; i++) {
            float a = U.cuStep * float(i);
            chroma[row + i] = pb[row + i] * float2(cos(a), -sin(a));
        }
        for (int pass = 0; pass < 2; pass++) {
            float4 sr = float4(0.0), si = float4(0.0);
            for (uint i = 0; i < N; i++) {
                float2 c = chroma[row + i];
                chroma[row + i] = float2(biquad(sr, c.x, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2),
                                         biquad(si, c.y, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2));
            }
            sr = float4(0.0); si = float4(0.0);
            for (int i = int(N) - 1; i >= 0; i--) {
                float2 c = chroma[row + uint(i)];
                chroma[row + uint(i)] = float2(biquad(sr, c.x, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2),
                                               biquad(si, c.y, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2));
            }
        }
        // Mixing halves the amplitude; recover chroma units.
        float k = 2.0 / U.chromaLevel;
        float2 b = float2(0.0);
        int cnt = 0;
        for (uint i = 0; i < N; i++) {
            float u = (float(i) + 0.5) * U.dt;
            float2 c = chroma[row + i] * k;
            chroma[row + i] = c;
            if (u >= BURST_S + 0.3 && u < BURST_E - 0.3) { b += c; cnt++; }
        }
        burst[y] = b / float(max(cnt, 1));
    }

    // ---- 7: ACC, APC and color killer, down the field ----
    kernel void vcr_acc(constant VcrU& U [[buffer(0)]],
                        device const float2* burst [[buffer(9)]],
                        device float4* color [[buffer(10)]],
                        uint tid [[thread_position_in_grid]])
    {
        if (tid != 0u) return;
        float2 ref = BURST_DIR * U.burstAmp;
        float nominal = U.burstAmp;
        float gain = 1.0, phase = 0.0, killer = 1.0;
        bool on = true;
        for (uint y = 0; y < U.rows; y++) {
            float2 b = burst[y];
            float mag = length(b);
            // Phase error against the reference burst direction.
            float err = atan2(ref.x * b.y - ref.y * b.x, ref.x * b.x + ref.y * b.y);
            if (mag > 0.15 * nominal) phase += 0.35 * (err - phase);
            gain += 0.3 * (nominal / max(mag, 0.12 * nominal) - gain);
            gain = clamp(gain, 0.3, 8.0);
            killer += 0.2 * (clamp(mag / nominal, 0.0, 1.0) - killer);
            if (on && killer < 0.15) on = false;
            else if (!on && killer > 0.3) on = true;
            color[y] = float4(cos(-phase), sin(-phase), on ? gain : 0.0, 0.0);
        }
    }

    // ---- 8: back to pixels, with dropout compensation ----
    kernel void vcr_out(constant VcrU& U [[buffer(0)]],
                        device const float* luma [[buffer(7)]],
                        device const float2* chroma [[buffer(8)]],
                        device const float4* color [[buffer(10)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= U.width || gid.y >= U.rows) return;
        float u0 = ACT_S + float(gid.x) * U.usPerPixel;
        int n0 = int(floor(u0 / U.dt));
        int n1 = max(n0 + 1, int(floor((u0 + U.usPerPixel) / U.dt)));
        n1 = min(n1, int(U.n));
        float ire = 0.0;
        float2 c = float2(0.0);
        for (int i = n0; i < n1; i++) {
            float v = luma[gid.y * U.n + uint(i)];
            if (v > 5000.0) {
                v -= 10000.0;
                // Dropout: with compensation, the deck replays the line
                // before from its one-line delay — that line's own output,
                // so a tall flaw repeats one line down several.
                if (U.doc != 0u) {
                    for (int k = 1; k <= 8 && int(gid.y) - k >= 0; k++) {
                        float w = luma[uint(int(gid.y) - k) * U.n + uint(i)];
                        if (w < 5000.0) { v = w; break; }
                        v = w - 10000.0;
                    }
                }
            }
            ire += v;
            c += chroma[gid.y * U.n + uint(i)];
        }
        float cnt = float(n1 - n0);
        ire /= cnt; c /= cnt;
        float4 rc = color[gid.y];
        float2 iq = float2(c.x * rc.x - c.y * rc.y, c.x * rc.y + c.y * rc.x) * rc.z;
        float3 yiq = float3((ire - 7.5) / 92.5, iq.x, iq.y);
        dst.write(float4(clamp(yiq2rgb(yiq), 0.0, 1.0), 1.0), gid);
    }
    """
}
