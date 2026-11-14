// The Glitch stage's GPU passes: a WGSL port of the Mac's GlitchStage Metal
// kernels, same arithmetic.
//  1. glitch_gate (a thread per row): what the TV's burst gate sees.
//  2. glitch_chroma (one thread): the color reference loop down the rows.
//  3. glitch_compose (a thread per pixel): the signal each screen pixel was
//     scanned from, plus ghost, hum, snow, decoded against the row's color
//     reference. With the VCR playing, the picture is its output (vcr.wgsl).
// A healthy set in lock reproduces its input exactly.

struct GlitchU {
    width: u32, activeLines: u32, vbiLines: u32, totalLines: u32,
    preEqEnd: u32, vsyncEnd: u32, postEqEnd: u32, ccEnabled: u32,
    ccBits: u32, fieldIndex: u32, seed: u32, pad0: u32,
    pad1: u32, tapsI: u32, tapsQ: u32, colorOnInit: u32,
    usPerPixel: f32, lineUS: f32, ghostLevel: f32, ghostDelay: f32,
    ghostCos: f32, ghostSin: f32, brightness: f32, pictureGain: f32,
    burstAmp: f32, chromaAlpha: f32, accGamma: f32, killerKappa: f32,
    phaseInit: f32, gainInit: f32, killerInit: f32, gateNoise: f32,
};
struct Row {
    u0: f32, fieldLine: i32, lenPrev: f32, lenCur: f32, lenNext: f32,
    noiseIRE: f32, humIRE: f32, burstScale: f32,
    pad0: f32, gateShift: f32, pad1: f32, pad2: f32,
};

const SYNC_END: f32 = 4.7;
const BURST_S: f32 = 5.3;
const BURST_E: f32 = 7.8;
const GATE_S: f32 = 4.55;
const GATE_E: f32 = 8.55;
const ACT_S: f32 = 9.4;
const ACT_L: f32 = 52.656;
const EQ_PULSE: f32 = 2.3;
const BROAD: f32 = 27.1;
const BURST_DIR: vec2<f32> = vec2<f32>(0.5446390350, -0.8386705679);

@group(0) @binding(0) var<uniform> U: GlitchU;
@group(0) @binding(1) var<storage, read> rows: array<Row>;
@group(0) @binding(2) var<storage, read_write> gate: array<vec2<f32>>;
@group(0) @binding(3) var<storage, read_write> color: array<vec4<f32>>;
@group(0) @binding(5) var src: texture_2d<f32>;
@group(0) @binding(6) var dst: texture_storage_2d<rgba8unorm, write>;

// ---- color space (NTSC Y'IQ on the gamma-encoded picture) ----
fn rgb2yiq(c: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(0.299 * c.r + 0.587 * c.g + 0.114 * c.b,
                     0.596 * c.r - 0.274 * c.g - 0.322 * c.b,
                     0.211 * c.r - 0.523 * c.g + 0.312 * c.b);
}
fn yiq2rgb(y: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(y.x + 0.9561706854 * y.y + 0.6214325663 * y.z,
                     y.x - 0.2726886023 * y.y - 0.6468132370 * y.z,
                     y.x - 1.1037440822 * y.y + 1.7006230947 * y.z);
}
fn ire2y(ire: f32) -> f32 { return (ire - 7.5) / 92.5; }

// ---- deterministic noise ----
fn hash4(a: u32, b: u32, c: u32, d: u32) -> u32 {
    var h = a * 0x8DA6B343u ^ b * 0xD8163841u ^ c * 0xCB1AB31Fu ^ d * 0x165667B1u;
    h ^= h >> 15u; h *= 0x2C1B3C6Du; h ^= h >> 12u; h *= 0x297A2D39u; h ^= h >> 15u;
    return h;
}
fn uni(a: u32, b: u32, c: u32, d: u32) -> f32 {
    return (f32(hash4(a, b, c, d) >> 8u) + 0.5) * (1.0 / 16777216.0);
}
fn gauss(a: u32, b: u32, c: u32, d: u32) -> f32 {
    let u1 = uni(a, b, c, d);
    let u2 = uni(a ^ 0x5bd1e995u, b, c, d + 7u);
    return sqrt(-2.0 * log(u1)) * cos(6.2831853 * u2);
}

// ---- where in the signal a moment of a TV line falls ----
struct Loc { line: i32, u: f32, };
fn locate(rw: Row, u_in: f32, L: u32) -> Loc {
    var line = rw.fieldLine;
    var u = u_in;
    if (u < 0.0) { u += rw.lenPrev; line -= 1; }
    else if (u >= rw.lenCur) {
        u -= rw.lenCur; line += 1;
        if (u >= rw.lenNext) { u -= rw.lenNext; line += 1; }
    }
    let iL = i32(L);
    line = ((line % iL) + iL) % iL;
    return Loc(line, u);
}

// Line 21: 7 cycles of clock run-in at 503.5 kHz, then 19 bits.
fn captionIRE(u: f32, bits: u32) -> f32 {
    let t = u - 10.5;
    let period = 1.986;
    if (t < 0.0) { return 0.0; }
    if (t < 7.0 * period) { return 25.0 - 25.0 * cos(6.2831853 * t / period); }
    let b = (t - 7.0 * period) / period;
    let k = i32(floor(b));
    if (k < 0 || k >= 19) { return 0.0; }
    let on = f32((bits >> u32(k)) & 1u);
    var prev = 0.0;
    if (k > 0) { prev = f32((bits >> u32(k - 1)) & 1u); }
    let edge = smoothstep(0.0, 0.25, b - f32(k));
    return 50.0 * mix(prev, on, edge);
}

// What the signal carries at (line, u): Y'IQ on the decoder's scale, and the
// raw texel + exactness flag when it's a picture pixel.
struct Sig { yiq: vec3<f32>, rgb: vec3<f32>, picture: bool, exact: bool, };
fn signalAt(line: i32, u: f32) -> Sig {
    var s = Sig(vec3<f32>(0.0), vec3<f32>(0.0), false, false);
    let vbi = i32(U.vbiLines);
    let halfLine = U.lineUS * 0.5;
    var ire = 0.0;
    if (line < vbi) {
        if (line < i32(U.preEqEnd) || (line >= i32(U.vsyncEnd) && line < i32(U.postEqEnd))) {
            if (u < EQ_PULSE || (u >= halfLine && u < halfLine + EQ_PULSE)) { ire = -40.0; }
        } else if (line < i32(U.vsyncEnd)) {
            if (u < BROAD || (u >= halfLine && u < halfLine + BROAD)) { ire = -40.0; }
        } else {
            if (u < SYNC_END) { ire = -40.0; }
            else if (line == vbi - 1 && U.ccEnabled != 0u && u >= ACT_S && u < ACT_S + ACT_L) {
                ire = captionIRE(u, U.ccBits);
            }
        }
        s.yiq = vec3<f32>(ire2y(ire), 0.0, 0.0);
        return s;
    }
    if (u < SYNC_END) { s.yiq = vec3<f32>(ire2y(-40.0), 0.0, 0.0); return s; }
    if (u < ACT_S || u >= ACT_S + ACT_L) { s.yiq = vec3<f32>(ire2y(0.0), 0.0, 0.0); return s; }
    let row = line - vbi;
    let xs = (u - ACT_S) / U.usPerPixel - 0.5;
    let x0 = floor(xs);
    let f = xs - x0;
    let w = i32(U.width);
    let ix = i32(x0);
    if (f < 1e-3 || f > 1.0 - 1e-3) {
        var xi = ix;
        if (f >= 0.5) { xi = ix + 1; }
        xi = clamp(xi, 0, w - 1);
        s.rgb = textureLoad(src, vec2<i32>(xi, row), 0).rgb;
        s.exact = true;
    } else {
        let a = textureLoad(src, vec2<i32>(clamp(ix, 0, w - 1), row), 0).rgb;
        let b = textureLoad(src, vec2<i32>(clamp(ix + 1, 0, w - 1), row), 0).rgb;
        s.rgb = mix(a, b, f);
    }
    s.picture = true;
    s.yiq = rgb2yiq(s.rgb);
    return s;
}

// ---- pass 1: the burst gate ----
@compute @workgroup_size(64)
fn glitch_gate(@builtin(global_invocation_id) id: vec3<u32>) {
    let y = id.x;
    if (y >= U.activeLines) { return; }
    let rw = rows[y];
    var g = vec2<f32>(0.0);
    let N = 16;
    for (var i = 0; i < N; i++) {
        let u = rw.u0 + rw.gateShift + GATE_S + (f32(i) + 0.5) / f32(N) * (GATE_E - GATE_S);
        let l = locate(rw, u, U.totalLines);
        if (l.line >= i32(U.postEqEnd) && l.u >= BURST_S && l.u < BURST_E) {
            g += BURST_DIR * U.burstAmp * rw.burstScale;
        } else if (l.line >= i32(U.vbiLines) && l.u >= ACT_S && l.u < ACT_S + ACT_L) {
            let s = signalAt(l.line, l.u);
            g += s.yiq.yz * U.pictureGain;
        }
    }
    // Normalized so a centered gate (10 of its 16 samples on the burst)
    // reads the burst at full amplitude.
    g *= (GATE_E - GATE_S) / ((BURST_E - BURST_S) * f32(N));
    let n = rw.noiseIRE / 92.5 * U.gateNoise;
    if (n > 0.0) {
        g += vec2<f32>(gauss(U.seed, U.fieldIndex, y, 101u), gauss(U.seed, U.fieldIndex, y, 102u)) * n;
    }
    gate[y] = g;
}

// ---- pass 2: the color reference loop, top to bottom ----
@compute @workgroup_size(1)
fn glitch_chroma(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x != 0u) { return; }
    var phase = U.phaseInit;
    var gain = U.gainInit;
    var killer = U.killerInit;
    var on = U.colorOnInit != 0u;
    let b0 = 0.2162162162;
    for (var y = 0u; y < U.activeLines; y++) {
        let g = gate[y];
        let mag = length(g);
        let c = cos(-phase);
        let s = sin(-phase);
        let r = vec2<f32>(g.x * c - g.y * s, g.x * s + g.y * c);
        let d = dot(r, BURST_DIR);
        let x = BURST_DIR.x * r.y - BURST_DIR.y * r.x;
        if (mag > 0.0) { phase += U.chromaAlpha * min(1.0, mag / b0) * atan2(x, d); }
        let c2 = cos(-phase);
        let s2 = sin(-phase);
        let inPhase = dot(vec2<f32>(g.x * c2 - g.y * s2, g.x * s2 + g.y * c2), BURST_DIR);
        gain += U.accGamma * (b0 / max(inPhase, 0.25 * b0) - gain);
        gain = clamp(gain, 0.3, 3.0);
        killer += U.killerKappa * (clamp(inPhase / b0, -1.0, 1.0) - killer);
        if (on && killer < 0.3) { on = false; }
        else if (!on && killer > 0.5) { on = true; }
        var ph = phase;
        if (abs(phase) < 1e-4) { ph = 0.0; }
        var gn = gain;
        if (abs(gain - 1.0) < 1e-4) { gn = 1.0; }
        var amp = 0.0;
        if (on) { amp = gn; }
        color[y] = vec4<f32>(cos(-ph), sin(-ph), amp, 0.0);
    }
}

// ---- pass 3: compose the screen ----
@compute @workgroup_size(8, 8)
fn glitch_compose(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= U.width || gid.y >= U.activeLines) { return; }
    let rw = rows[gid.y];
    let rc = color[gid.y];
    let u = rw.u0 + ACT_S + (f32(gid.x) + 0.5) * U.usPerPixel;
    let l = locate(rw, u, U.totalLines);

    let s = signalAt(l.line, l.u);
    let plain = s.picture && s.exact
        && U.ghostLevel == 0.0 && rw.noiseIRE == 0.0 && rw.humIRE == 0.0
        && U.pictureGain == 1.0 && U.brightness == 0.0
        && rc.x == 1.0 && rc.y == 0.0 && rc.z == 1.0;
    if (plain) { textureStore(dst, vec2<i32>(gid.xy), vec4<f32>(s.rgb, 1.0)); return; }

    var yiq = s.yiq;

    // Multipath: the same signal again, later, possibly inverted.
    if (U.ghostLevel != 0.0) {
        var ug = l.u - U.ghostDelay;
        var gl = l.line;
        if (ug < 0.0) { ug += U.lineUS; gl = (gl - 1 + i32(U.totalLines)) % i32(U.totalLines); }
        let g = signalAt(gl, ug);
        let iq = vec2<f32>(g.yiq.y * U.ghostCos - g.yiq.z * U.ghostSin,
                           g.yiq.y * U.ghostSin + g.yiq.z * U.ghostCos);
        yiq.x += U.ghostLevel * (g.yiq.x - ire2y(0.0));
        yiq = vec3<f32>(yiq.x, yiq.yz + U.ghostLevel * iq);
    }

    // AGC running out of gain: everything shrinks toward blanking.
    if (U.pictureGain != 1.0) {
        let ire = 7.5 + 92.5 * yiq.x;
        yiq.x = ire2y(ire * U.pictureGain);
        yiq = vec3<f32>(yiq.x, yiq.yz * U.pictureGain);
    }

    yiq.x += rw.humIRE / 92.5;

    // Snow with the decoder's spectrum.
    if (rw.noiseIRE > 0.0) {
        let n = rw.noiseIRE / 92.5;
        yiq.x += gauss(U.seed, U.fieldIndex, gid.x, gid.y * 3u) * n;
        var ni = 0.0;
        var nq = 0.0;
        for (var k = 0u; k < U.tapsI; k++) { ni += gauss(U.seed ^ 0x1234u, U.fieldIndex, gid.x + k, gid.y * 3u + 1u); }
        for (var k = 0u; k < U.tapsQ; k++) { nq += gauss(U.seed ^ 0x4321u, U.fieldIndex, gid.x + k, gid.y * 3u + 2u); }
        yiq.y += ni / sqrt(f32(U.tapsI)) * n * 0.35;
        yiq.z += nq / sqrt(f32(U.tapsQ)) * n * 0.25;
    }

    // Decode chroma against the row's reference.
    let iq = vec2<f32>(yiq.y * rc.x - yiq.z * rc.y, yiq.y * rc.y + yiq.z * rc.x) * rc.z;
    yiq.y = iq.x;
    yiq.z = iq.y;

    // Brightness lowers the tube's cutoff: blanking and sync become visible.
    if (U.brightness > 0.0) {
        let cutoff = 7.5 - 47.5 * U.brightness;
        let ire = 7.5 + 92.5 * yiq.x;
        yiq.x = (ire - cutoff) / (100.0 - cutoff);
        yiq = vec3<f32>(yiq.x, yiq.yz * (92.5 / (100.0 - cutoff)));
    }

    let rgb = clamp(yiq2rgb(yiq), vec3<f32>(0.0), vec3<f32>(1.0));
    textureStore(dst, vec2<i32>(gid.xy), vec4<f32>(rgb, 1.0));
}
