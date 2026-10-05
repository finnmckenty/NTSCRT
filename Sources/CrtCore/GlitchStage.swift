import Foundation
import Metal

/// GPU half of the glitch stage: draws the field the receiver simulation
/// says the TV displays. Three passes:
///
/// 1. `glitch_gate` (one thread per row): what the TV's burst gate sees —
///    the burst when the set is in lock, picture or blanking when it isn't.
/// 2. `glitch_chroma` (one thread): the color reference loop down the
///    rows — 3.58 MHz oscillator phase, ACC gain, color killer — the same
///    recurrence `ChromaReference` runs on the CPU.
/// 3. `glitch_compose` (one thread per pixel): reads the signal each screen
///    pixel was scanned from — picture, blanking, sync pulses, line-21
///    caption data — then adds the ghost, dropouts, hum and snow, and
///    decodes color against the row's reference.
///
/// Linear signal effects (ghost, hum, snow) are added after ntsc-rs has
/// decoded the picture. For a linear decoder that is exact, not an
/// approximation: decode(signal + ghost) = decode(signal) + decode(ghost),
/// and a decoded delayed copy is the picture shifted with its chroma rotated
/// by the subcarrier phase of the delay. Snow is added with the spectrum the
/// decoder would have given it.
///
/// A healthy set in lock reproduces its input exactly: every pixel samples
/// its own texel, and no color math runs.
public final class GlitchStage {

    private let device: MTLDevice
    private let gatePipeline: MTLComputePipelineState
    private let chromaPipeline: MTLComputePipelineState
    private let composePipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        func pipe(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw NSError(domain: "GlitchStage", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "missing kernel \(name)"])
            }
            return try device.makeComputePipelineState(function: fn)
        }
        gatePipeline = try pipe("glitch_gate")
        chromaPipeline = try pipe("glitch_chroma")
        composePipeline = try pipe("glitch_compose")
    }

    /// Mirrors `GlitchU` in the shader: 4-byte scalars only, so the Swift
    /// and MSL layouts agree.
    private struct Uniforms {
        var width: UInt32, activeLines: UInt32, vbiLines: UInt32, totalLines: UInt32
        var preEqEnd: UInt32, vsyncEnd: UInt32, postEqEnd: UInt32, ccEnabled: UInt32
        var ccBits: UInt32, fieldIndex: UInt32, seed: UInt32, dropoutCount: UInt32
        var docEnabled: UInt32, tapsI: UInt32, tapsQ: UInt32, colorOnInit: UInt32
        var usPerPixel: Float, lineUS: Float, ghostLevel: Float, ghostDelay: Float
        var ghostCos: Float, ghostSin: Float, brightness: Float, pictureGain: Float
        var burstAmp: Float, chromaAlpha: Float, accGamma: Float, killerKappa: Float
        var phaseInit: Float, gainInit: Float, killerInit: Float, gateNoise: Float
    }

    public func encode(into cb: MTLCommandBuffer,
                       input: MTLTexture,
                       output: MTLTexture,
                       plan: GlitchFieldPlan) {
        let raster = plan.raster
        let rows = plan.rows
        guard rows.count == input.height, output.width == input.width,
              output.height == input.height, !rows.isEmpty else { return }
        let s = plan.settings
        let knobs = Knobs(s, raster: raster)
        let usPerPixel = NTSCTiming.activeLength / Double(input.width)
        let ghostDelay = s["ghost_delay"]
        // A delayed copy's chroma arrives 2π·fsc·τ late in phase.
        let ghostAngle = -2 * Double.pi * NTSCTiming.subcarrierMHz * ghostDelay
        func snap(_ v: Float, to target: Float) -> Float { abs(v - target) < 1e-6 ? target : v }

        var u = Uniforms(
            width: UInt32(input.width), activeLines: UInt32(raster.activeLines),
            vbiLines: UInt32(raster.vbiLines), totalLines: UInt32(raster.totalLines),
            preEqEnd: UInt32(raster.preEqEnd), vsyncEnd: UInt32(raster.vsyncEnd),
            postEqEnd: UInt32(raster.postEqEnd), ccEnabled: s.flag("closed_captions") ? 1 : 0,
            ccBits: plan.ccBits, fieldIndex: plan.fieldIndex, seed: 0x9E3779B9,
            dropoutCount: UInt32(min(plan.dropouts.count, 64)),
            docEnabled: s.flag("dropout_compensation") ? 1 : 0,
            // Decoder chroma bandwidths: I ≈ 1.3 MHz, Q ≈ 0.6 MHz.
            tapsI: UInt32(max(1, Int((0.38 / usPerPixel).rounded()))),
            tapsQ: UInt32(max(1, Int((0.83 / usPerPixel).rounded()))),
            colorOnInit: plan.colorOn ? 1 : 0,
            usPerPixel: Float(usPerPixel), lineUS: Float(NTSCTiming.line),
            ghostLevel: Float(s["ghost_level"]), ghostDelay: Float(ghostDelay),
            ghostCos: Float(cos(ghostAngle)), ghostSin: Float(sin(ghostAngle)),
            brightness: Float(min(1, max(0, s["brightness"]))),
            pictureGain: snap(plan.pictureGain, to: 1),
            burstAmp: Float(NTSCTiming.burstAmplitude * knobs.agc),
            chromaAlpha: Float(knobs.chromaAlpha), accGamma: Float(knobs.accGamma),
            killerKappa: Float(knobs.killerKappa),
            phaseInit: snap(plan.chromaPhase, to: 0), gainInit: snap(plan.chromaGain, to: 1),
            killerInit: snap(plan.killer, to: 1), gateNoise: 0.45)

        let rowBytes = rows.count * MemoryLayout<GlitchRow>.stride
        guard let rowBuf = rows.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: rowBytes,
                                                                    options: .storageModeShared) }),
              let gateBuf = device.makeBuffer(length: rows.count * 8, options: .storageModePrivate),
              let colorBuf = device.makeBuffer(length: rows.count * 16, options: .storageModePrivate)
        else { return }
        var dropouts = Array(plan.dropouts.prefix(64))
        if dropouts.isEmpty { dropouts = [GlitchDropout(fieldLine: -1, uStart: 0, uLength: 0)] }

        guard let enc = cb.makeComputeCommandEncoder() else { return }

        enc.setComputePipelineState(gatePipeline)
        enc.setBuffer(rowBuf, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setBuffer(gateBuf, offset: 0, index: 2)
        enc.setTexture(input, index: 0)
        let rowThreads = MTLSize(width: rows.count, height: 1, depth: 1)
        let rowGroup = MTLSize(width: min(64, gatePipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        enc.dispatchThreads(rowThreads, threadsPerThreadgroup: rowGroup)

        enc.setComputePipelineState(chromaPipeline)
        enc.setBuffer(gateBuf, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setBuffer(colorBuf, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        enc.setComputePipelineState(composePipeline)
        enc.setBuffer(rowBuf, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setBuffer(colorBuf, offset: 0, index: 2)
        dropouts.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 3) }
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        let w = composePipeline.threadExecutionWidth
        let h = max(1, composePipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlitchU {
        uint width, activeLines, vbiLines, totalLines;
        uint preEqEnd, vsyncEnd, postEqEnd, ccEnabled;
        uint ccBits, fieldIndex, seed, dropoutCount;
        uint docEnabled, tapsI, tapsQ, colorOnInit;
        float usPerPixel, lineUS, ghostLevel, ghostDelay;
        float ghostCos, ghostSin, brightness, pictureGain;
        float burstAmp, chromaAlpha, accGamma, killerKappa;
        float phaseInit, gainInit, killerInit, gateNoise;
    };
    struct Row {
        float u0; int fieldLine; float lenPrev; float lenCur; float lenNext;
        float noiseIRE; float humIRE; float burstScale;
        float tapeLoss; float gateShift; float pad1; float pad2;
    };
    struct Dropout { int fieldLine; float uStart; float uLength; float pad; };

    constant float SYNC_END = 4.7;
    constant float BURST_S = 5.3;
    constant float BURST_E = 7.8;
    constant float GATE_S = 4.55;           // 4 µs gate around the burst
    constant float GATE_E = 8.55;
    constant float ACT_S = 9.4;
    constant float ACT_L = 52.656;
    constant float EQ_PULSE = 2.3;
    constant float BROAD = 27.1;
    constant float2 BURST_DIR = float2(0.5446390350, -0.8386705679);

    // ---- color space (NTSC Y'IQ on the gamma-encoded picture) ----
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
    inline float ire2y(float ire) { return (ire - 7.5) / 92.5; }

    // ---- deterministic noise ----
    inline uint hash4(uint a, uint b, uint c, uint d) {
        uint h = a * 0x8DA6B343u ^ b * 0xD8163841u ^ c * 0xCB1AB31Fu ^ d * 0x165667B1u;
        h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
        return h;
    }
    inline float uni(uint a, uint b, uint c, uint d) {
        return (float(hash4(a, b, c, d) >> 8) + 0.5) * (1.0 / 16777216.0);
    }
    inline float gauss(uint a, uint b, uint c, uint d) {
        float u1 = uni(a, b, c, d);
        float u2 = uni(a ^ 0x5bd1e995u, b, c, d + 7u);
        return sqrt(-2.0 * log(u1)) * cos(6.2831853 * u2);
    }

    // ---- where in the signal a moment of a TV line falls ----
    struct Loc { int line; float u; };
    inline Loc locate(Row rw, float u, uint L) {
        int line = rw.fieldLine;
        if (u < 0.0) { u += rw.lenPrev; line -= 1; }
        else if (u >= rw.lenCur) {
            u -= rw.lenCur; line += 1;
            if (u >= rw.lenNext) { u -= rw.lenNext; line += 1; }
        }
        int iL = int(L);
        line = ((line % iL) + iL) % iL;
        return { line, u };
    }

    // Is (line, u) inside a dropout? Reports where that dropout starts.
    inline bool inDropout(constant Dropout* drops, uint count, int line, float u, thread float& start) {
        for (uint i = 0; i < count; i++) {
            Dropout d = drops[i];
            if (d.fieldLine == line && u >= d.uStart && u < d.uStart + d.uLength) {
                start = d.uStart;
                return true;
            }
        }
        return false;
    }

    // Line 21: 7 cycles of clock run-in at 503.5 kHz, then 19 bits.
    inline float captionIRE(float u, uint bits) {
        float t = u - 10.5;
        const float period = 1.986;
        if (t < 0.0) return 0.0;
        if (t < 7.0 * period) return 25.0 - 25.0 * cos(6.2831853 * t / period);
        float b = (t - 7.0 * period) / period;
        int k = int(floor(b));
        if (k < 0 || k >= 19) return 0.0;
        float on = float((bits >> uint(k)) & 1u);
        float prev = k > 0 ? float((bits >> uint(k - 1)) & 1u) : 0.0;
        float edge = smoothstep(0.0, 0.25, b - float(k));
        return 50.0 * mix(prev, on, edge);
    }

    // What the signal carries at (line, u): returns Y'IQ on the decoder's
    // scale, and the raw texel + exactness flag when it is a picture pixel.
    struct Sig { float3 yiq; float3 rgb; bool picture; bool exact; };
    inline Sig signalAt(texture2d<float, access::read> src, constant GlitchU& U, int line, float u) {
        Sig s; s.picture = false; s.exact = false; s.rgb = float3(0.0);
        int vbi = int(U.vbiLines);
        float halfLine = U.lineUS * 0.5;
        float ire = 0.0;                                   // blanking
        if (line < vbi) {
            if (line < int(U.preEqEnd) || (line >= int(U.vsyncEnd) && line < int(U.postEqEnd))) {
                if (u < EQ_PULSE || (u >= halfLine && u < halfLine + EQ_PULSE)) ire = -40.0;
            } else if (line < int(U.vsyncEnd)) {
                if (u < BROAD || (u >= halfLine && u < halfLine + BROAD)) ire = -40.0;
            } else {
                if (u < SYNC_END) ire = -40.0;
                else if (line == vbi - 1 && U.ccEnabled != 0u && u >= ACT_S && u < ACT_S + ACT_L)
                    ire = captionIRE(u, U.ccBits);
            }
            s.yiq = float3(ire2y(ire), 0.0, 0.0);
            return s;
        }
        if (u < SYNC_END) { s.yiq = float3(ire2y(-40.0), 0.0, 0.0); return s; }
        if (u < ACT_S || u >= ACT_S + ACT_L) { s.yiq = float3(ire2y(0.0), 0.0, 0.0); return s; }
        int row = line - vbi;
        float xs = (u - ACT_S) / U.usPerPixel - 0.5;
        float x0 = floor(xs);
        float f = xs - x0;
        int w = int(U.width);
        int ix = int(x0);
        if (f < 1e-3 || f > 1.0 - 1e-3) {
            int xi = clamp(f < 0.5 ? ix : ix + 1, 0, w - 1);
            s.rgb = src.read(uint2(uint(xi), uint(row))).rgb;
            s.exact = true;
        } else {
            float3 a = src.read(uint2(uint(clamp(ix, 0, w - 1)), uint(row))).rgb;
            float3 b = src.read(uint2(uint(clamp(ix + 1, 0, w - 1)), uint(row))).rgb;
            s.rgb = mix(a, b, f);
        }
        s.picture = true;
        s.yiq = rgb2yiq(s.rgb);
        return s;
    }

    // ---- pass 1: the burst gate ----
    kernel void glitch_gate(device const Row* rows [[buffer(0)]],
                            constant GlitchU& U [[buffer(1)]],
                            device float2* gate [[buffer(2)]],
                            texture2d<float, access::read> src [[texture(0)]],
                            uint y [[thread_position_in_grid]])
    {
        if (y >= U.activeLines) return;
        Row rw = rows[y];
        float2 g = float2(0.0);
        const int N = 16;
        for (int i = 0; i < N; i++) {
            float u = rw.u0 + rw.gateShift + GATE_S + (float(i) + 0.5) / float(N) * (GATE_E - GATE_S);
            Loc l = locate(rw, u, U.totalLines);
            if (l.line >= int(U.postEqEnd) && l.u >= BURST_S && l.u < BURST_E) {
                g += BURST_DIR * U.burstAmp * rw.burstScale;
            } else if (l.line >= int(U.vbiLines) && l.u >= ACT_S && l.u < ACT_S + ACT_L) {
                Sig s = signalAt(src, U, l.line, l.u);
                g += s.yiq.yz * U.pictureGain;
            }
        }
        // Normalized so a centered gate (10 of its 16 samples on the burst)
        // reads the burst at full amplitude.
        g *= (GATE_E - GATE_S) / ((BURST_E - BURST_S) * float(N));
        float n = rw.noiseIRE / 92.5 * U.gateNoise;
        if (n > 0.0) {
            g += float2(gauss(U.seed, U.fieldIndex, y, 101u), gauss(U.seed, U.fieldIndex, y, 102u)) * n;
        }
        gate[y] = g;
    }

    // ---- pass 2: the color reference loop, top to bottom ----
    kernel void glitch_chroma(device const float2* gate [[buffer(0)]],
                              constant GlitchU& U [[buffer(1)]],
                              device float4* color [[buffer(2)]],
                              uint tid [[thread_position_in_grid]])
    {
        if (tid != 0u) return;
        float phase = U.phaseInit, gain = U.gainInit, killer = U.killerInit;
        bool on = U.colorOnInit != 0u;
        float b0 = 0.2162162162;                           // 20 IRE burst
        for (uint y = 0; y < U.activeLines; y++) {
            float2 g = gate[y];
            float mag = length(g);
            float c = cos(-phase), s = sin(-phase);
            float2 r = float2(g.x * c - g.y * s, g.x * s + g.y * c);
            float d = dot(r, BURST_DIR);
            float x = BURST_DIR.x * r.y - BURST_DIR.y * r.x;
            if (mag > 0.0) phase += U.chromaAlpha * min(1.0, mag / b0) * atan2(x, d);
            float c2 = cos(-phase), s2 = sin(-phase);
            float inPhase = dot(float2(g.x * c2 - g.y * s2, g.x * s2 + g.y * c2), BURST_DIR);
            gain += U.accGamma * (b0 / max(inPhase, 0.25 * b0) - gain);
            gain = clamp(gain, 0.3, 3.0);
            killer += U.killerKappa * (clamp(inPhase / b0, -1.0, 1.0) - killer);
            if (on && killer < 0.3) on = false;
            else if (!on && killer > 0.5) on = true;
            float ph = fabs(phase) < 1e-4 ? 0.0 : phase;
            float gn = fabs(gain - 1.0) < 1e-4 ? 1.0 : gain;
            color[y] = float4(cos(-ph), sin(-ph), on ? gn : 0.0, 0.0);
        }
    }

    // ---- pass 3: compose the screen ----
    kernel void glitch_compose(device const Row* rows [[buffer(0)]],
                               constant GlitchU& U [[buffer(1)]],
                               device const float4* color [[buffer(2)]],
                               constant Dropout* drops [[buffer(3)]],
                               texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= U.width || gid.y >= U.activeLines) return;
        Row rw = rows[gid.y];
        float4 rc = color[gid.y];
        float u = rw.u0 + ACT_S + (float(gid.x) + 0.5) * U.usPerPixel;
        Loc l = locate(rw, u, U.totalLines);

        // Oxide dropout. Without compensation the FM demodulator throws a
        // white streak with a dark tail. With it, the deck replays the
        // stretch from its one-line delay — which, when the line above was
        // a dropout too, is that line's own replacement, so a tall flaw
        // repeats one line down several (a frozen smear). The detector and
        // switch react ~0.7 µs late, so each dropout still flashes a tick.
        int sigLine = l.line;
        bool streak = false;
        float tail = 0.0;
        float dStart = 0.0;
        if (inDropout(drops, U.dropoutCount, l.line, l.u, dStart)) {
            if (U.docEnabled != 0u && l.u - dStart >= 0.7) {
                int src = l.line - 1;
                float s2 = 0.0;
                for (int k = 0; k < 6 && src > int(U.vbiLines)
                     && inDropout(drops, U.dropoutCount, src, l.u, s2); k++) src -= 1;
                sigLine = max(int(U.vbiLines), src);
            } else {
                streak = true;
            }
        } else if (U.docEnabled == 0u) {
            for (uint i = 0; i < U.dropoutCount; i++) {
                Dropout d = drops[i];
                if (d.fieldLine == l.line && l.u >= d.uStart + d.uLength
                    && l.u < d.uStart + d.uLength + 1.5) {
                    tail = max(tail, 1.0 - (l.u - d.uStart - d.uLength) / 1.5);
                }
            }
        }

        Sig s = signalAt(src, U, sigLine, l.u);
        bool plain = s.picture && s.exact && sigLine == l.line && !streak && tail == 0.0
            && U.ghostLevel == 0.0 && rw.noiseIRE == 0.0 && rw.humIRE == 0.0 && rw.tapeLoss == 0.0
            && U.pictureGain == 1.0 && U.brightness == 0.0
            && rc.x == 1.0 && rc.y == 0.0 && rc.z == 1.0;
        if (plain) { dst.write(float4(s.rgb, 1.0), gid); return; }

        float3 yiq = s.yiq;
        if (streak) yiq = float3(1.0, 0.0, 0.0);
        if (tail > 0.0) yiq.x = mix(yiq.x, -0.08, tail * 0.6);

        // Multipath: the same signal again, later, possibly inverted.
        if (U.ghostLevel != 0.0) {
            float ug = l.u - U.ghostDelay;
            int gl = l.line;
            if (ug < 0.0) { ug += U.lineUS; gl = (gl - 1 + int(U.totalLines)) % int(U.totalLines); }
            Sig g = signalAt(src, U, gl, ug);
            float2 iq = float2(g.yiq.y * U.ghostCos - g.yiq.z * U.ghostSin,
                               g.yiq.y * U.ghostSin + g.yiq.z * U.ghostCos);
            // The ghost adds the signal's variation about blanking.
            yiq.x += U.ghostLevel * (g.yiq.x - ire2y(0.0));
            yiq.yz += U.ghostLevel * iq;
        }

        // Tape signal loss: past the FM threshold the deck's demodulator
        // outputs streaks instead of picture — black and white dashes a
        // fraction of a microsecond to a couple long — and its color
        // killer drops chroma with the signal.
        if (rw.tapeLoss > 0.0) {
            float seg = 0.5 + 1.6 * uni(U.seed, U.fieldIndex, gid.y, 201u);
            float pos = l.u + uni(U.seed, U.fieldIndex, gid.y, 202u) * seg;
            uint run = uint(max(0.0, pos) / seg);
            float g = gauss(U.seed ^ 0xF00Du, U.fieldIndex, run, gid.y);
            float sparkle = uni(U.seed ^ 0xBEEFu, U.fieldIndex, run, gid.y) > 0.93 ? 0.6 : 0.0;
            float streak = clamp(0.35 + 0.32 * g + sparkle, -0.08, 1.05);
            yiq.x = mix(yiq.x, streak, rw.tapeLoss);
            yiq.yz *= 1.0 - rw.tapeLoss;
        }

        // AGC running out of gain: everything shrinks toward blanking.
        if (U.pictureGain != 1.0) {
            float ire = 7.5 + 92.5 * yiq.x;
            yiq.x = ire2y(ire * U.pictureGain);
            yiq.yz *= U.pictureGain;
        }

        yiq.x += rw.humIRE / 92.5;

        // Snow with the decoder's spectrum: luma near-white, chroma
        // low-passed to the I and Q bandwidths.
        if (rw.noiseIRE > 0.0) {
            float n = rw.noiseIRE / 92.5;
            yiq.x += gauss(U.seed, U.fieldIndex, gid.x, gid.y * 3u) * n;
            float ni = 0.0, nq = 0.0;
            for (uint k = 0; k < U.tapsI; k++)
                ni += gauss(U.seed ^ 0x1234u, U.fieldIndex, gid.x + k, gid.y * 3u + 1u);
            for (uint k = 0; k < U.tapsQ; k++)
                nq += gauss(U.seed ^ 0x4321u, U.fieldIndex, gid.x + k, gid.y * 3u + 2u);
            // Chroma noise carries the I and Q channels' share of the
            // noise power (1.3 and 0.6 MHz of the 4.2 MHz video band).
            yiq.y += ni / sqrt(float(U.tapsI)) * n * 0.35;
            yiq.z += nq / sqrt(float(U.tapsQ)) * n * 0.25;
        }

        // Decode chroma against the row's reference: a phase error rotates
        // it, ACC scales it, the killer removes it.
        float2 iq = float2(yiq.y * rc.x - yiq.z * rc.y, yiq.y * rc.y + yiq.z * rc.x) * rc.z;
        yiq.y = iq.x; yiq.z = iq.y;

        // Brightness lowers the tube's cutoff: blanking (0 IRE) and sync
        // (−40) become visible as the black level drops below them.
        if (U.brightness > 0.0) {
            float cutoff = 7.5 - 47.5 * U.brightness;
            float ire = 7.5 + 92.5 * yiq.x;
            yiq.x = (ire - cutoff) / (100.0 - cutoff);
            yiq.yz *= 92.5 / (100.0 - cutoff);
        }

        float3 rgb = clamp(yiq2rgb(yiq), 0.0, 1.0);
        dst.write(float4(rgb, 1.0), gid);
    }
    """
}
