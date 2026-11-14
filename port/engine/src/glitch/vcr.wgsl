// The VCR's signal path: a port of the Mac's VcrStage Metal kernels (keep
// them in step). tape_at must agree with tape.rs.

struct VcrU {
    rows: u32, n: u32, segs: u32, width: u32,
    seed: u32, field: u32, doc: u32, fmReach: u32,
    levels: u32, reach: u32, linesPerField: u32, pad0: u32,
    usPerPixel: f32, dt: f32, lineUS: f32, lineLength: f32,
    pitch: f32, cosA: f32, sinA: f32, trackStart: f32,
    noise: f32, chromaLevel: f32, cuStep: f32, maxSpacing: f32,
    emB0: f32, emB1: f32, emA1: f32, whiteClip: f32,
    deB0: f32, deB1: f32, deA1: f32, darkClip: f32,
    lb0: f32, lb1: f32, lb2: f32, la1: f32,
    la2: f32, cb0: f32, cb1: f32, cb2: f32,
    ca1: f32, ca2: f32, docOn: f32, docOff: f32,
    wear: f32, dropouts: f32, scratches: f32, creases: f32,
    edge: f32, mold: f32, vaseline: f32, remanence: f32,
    roughness: f32, pinhole: f32, flake: f32, burstAmp: f32,
};
struct VcrLine {
    originBase: i32, originOffset: f32, along0: f32, spacing: f32,
    grease: f32, gain: f32, head: u32, pad: f32,
};

@group(0) @binding(0) var<uniform> U: VcrU;
@group(0) @binding(1) var<storage, read> lines: array<VcrLine>;
@group(0) @binding(2) var<storage, read_write> rf: array<f32>;
@group(0) @binding(3) var<storage, read_write> seg: array<vec2<f32>>;
@group(0) @binding(4) var<storage, read_write> mag: array<vec2<f32>>;
@group(0) @binding(5) var<storage, read_write> pb: array<f32>;
@group(0) @binding(6) var<storage, read_write> zb: array<vec2<f32>>;
@group(0) @binding(7) var<storage, read_write> luma: array<f32>;
@group(0) @binding(8) var<storage, read_write> chroma: array<vec2<f32>>;
@group(0) @binding(9) var<storage, read_write> burst: array<vec2<f32>>;
@group(0) @binding(10) var<storage, read_write> color: array<vec4<f32>>;
@group(0) @binding(11) var<storage, read> bank: array<f32>;
@group(0) @binding(12) var<storage, read> taps: array<vec2<f32>>;
@group(0) @binding(13) var src: texture_2d<f32>;
@group(0) @binding(14) var dst: texture_storage_2d<rgba16float, write>;

const SYNC_END: f32 = 4.7;
const BURST_S: f32 = 5.3;
const BURST_E: f32 = 7.8;
const ACT_S: f32 = 9.4;
const ACT_L: f32 = 52.656;
const TAPE_W: f32 = 12.65;
const TAU: f32 = 6.2831853;
const BURST_DIR: vec2<f32> = vec2<f32>(0.5446390350, -0.8386705679);

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

fn thash(a: u32, b: u32, c: u32, d: u32) -> u32 {
    var h = (a * 0x8DA6B343u) ^ (b * 0xD8163841u) ^ (c * 0xCB1AB31Fu) ^ (d * 0x165667B1u);
    h ^= h >> 15u; h *= 0x2C1B3C6Du; h ^= h >> 12u; h *= 0x297A2D39u; h ^= h >> 15u;
    return h;
}
fn tuni(a: u32, b: u32, c: i32, d: i32) -> f32 {
    return (f32(thash(a, b, bitcast<u32>(c), bitcast<u32>(d)) >> 8u) + 0.5) * (1.0 / 16777216.0);
}
fn gaussn(a: u32, b: u32, c: i32, d: i32) -> f32 {
    let u1 = tuni(a, b, c, d);
    let u2 = tuni(a ^ 0x5bd1e995u, b, c, d + 7);
    return sqrt(-2.0 * log(u1)) * cos(TAU * u2);
}
fn sm(t: f32) -> f32 { return t * t * (3.0 - 2.0 * t); }
fn sstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

struct TPos { base: i32, off: f32, y: f32, };
struct Cell { c: i32, f: f32, };
fn tcell(p: TPos, q: i32) -> Cell {
    let whole = floor(p.off);
    let t = p.base + i32(whole);
    var c = t / q;
    if (t % q != 0 && t < 0) { c -= 1; }
    return Cell(c, (f32(t - c * q) + (p.off - whole)) / f32(q));
}
fn tdx(p: TPos, c: i32, q: i32, frac: f32) -> f32 {
    return f32(c * q - p.base) + frac * f32(q) - p.off;
}
fn noise1(s: u32, k: u32, i: i32, f: f32) -> f32 {
    let a = tuni(s, k, i, 0);
    let b = tuni(s, k, i + 1, 0);
    return a + (b - a) * sm(f);
}
fn noise2(s: u32, k: u32, i: i32, fi: f32, j: i32, fj: f32) -> f32 {
    let a = tuni(s, k, i, j);
    let b = tuni(s, k, i + 1, j);
    let c = tuni(s, k, i, j + 1);
    let d = tuni(s, k, i + 1, j + 1);
    let u = sm(fi);
    let v = sm(fj);
    let lo = a + (b - a) * u;
    let hi = c + (d - c) * u;
    return lo + (hi - lo) * v;
}

struct TPt { lift: f32, film: f32, outp: f32, };
fn tape_at(p: TPos) -> TPt {
    let s = U.seed;
    let y = p.y;
    var lift = U.roughness;
    var outp = U.remanence;
    var film = 0.0;
    {
        let c = tcell(p, 5);
        let yy = y * 10.0;
        let cy = i32(floor(yy));
        outp *= 1.0 + (0.04 + 0.1 * U.wear) * (2.0 * noise2(s, 1u, c.c, c.f, cy, yy - f32(cy)) - 1.0);
    }
    if (U.pinhole > 0.0) {
        let c = tcell(p, 1);
        let cy = i32(floor(y * 10.0));
        for (var j = -1; j <= 1; j++) {
            for (var i = -1; i <= 1; i++) {
                let ci = c.c + i;
                let cj = cy + j;
                if (tuni(s, 11u, ci, cj) >= U.pinhole) { continue; }
                let ddx = tdx(p, ci, 1, tuni(s, 12u, ci, cj)) * 0.1;
                let ddy = (f32(cj) + tuni(s, 13u, ci, cj)) * 0.1 - y;
                let u = tuni(s, 14u, ci, cj);
                let r = 0.003 * pow(15.0, u * u);
                let d = sqrt(ddx * ddx + ddy * ddy);
                if (d < r) { outp *= sstep(r * 0.6, r, d); }
            }
        }
    }
    if (U.flake > 0.0) {
        let c = tcell(p, 10);
        let cy = i32(floor(y));
        for (var j = -1; j <= 1; j++) {
            for (var i = -1; i <= 1; i++) {
                let ci = c.c + i;
                let cj = cy + j;
                if (tuni(s, 21u, ci, cj) >= U.flake) { continue; }
                let ddx = tdx(p, ci, 10, tuni(s, 22u, ci, cj)) * 0.1;
                let ddy = f32(cj) + tuni(s, 23u, ci, cj) - y;
                let u = tuni(s, 24u, ci, cj);
                let r = 0.04 * pow(8.0, u * u);
                let e = 0.6 + 0.8 * tuni(s, 25u, ci, cj);
                let d = sqrt((ddx / e) * (ddx / e) + (ddy * e) * (ddy * e));
                if (d < r * 1.5) { outp *= sstep(r * 0.8, r, d); }
            }
        }
    }
    if (U.scratches > 0.0) {
        let lane = i32(floor(y * 4.0));
        let sx = tcell(p, 3000);
        for (var l = -2; l <= 2; l++) {
            let li = lane + l;
            if (tuni(s, 31u, li, sx.c) >= U.scratches * 0.3) { continue; }
            let a = tuni(s, 32u, li, sx.c);
            let b = tuni(s, 33u, li, sx.c);
            if (sx.f < min(a, b) * 0.6 || sx.f > 0.4 + max(a, b) * 0.6) { continue; }
            let yc = (f32(li) + 0.1 + 0.8 * tuni(s, 34u, li, sx.c)) * 0.25;
            let su = tuni(s, 35u, li, sx.c);
            let w = 0.02 + 0.2 * su * su * (0.5 + 0.5 * U.scratches);
            let dy = abs(y - yc);
            if (dy < w * 0.5) {
                outp *= 0.2 * tuni(s, 36u, li, sx.c);
                lift += 0.4 * U.scratches;
            } else if (dy < w * 1.5) {
                lift += 1.0 * U.scratches * (1.0 - (dy - w * 0.5) / w);
            }
        }
    }
    if (U.creases > 0.0) {
        let sx = tcell(p, 400);
        for (var k = -1; k <= 1; k++) {
            let ci = sx.c + k;
            if (tuni(s, 41u, ci, 0) >= U.creases * 0.9) { continue; }
            let off = tdx(p, ci, 400, tuni(s, 42u, ci, 0)) * 0.1;
            let slant = tan((tuni(s, 43u, ci, 0) - 0.5) * 0.7);
            let fromBottom = tuni(s, 44u, ci, 0) < 0.5;
            let extent = TAPE_W * (0.25 + 0.75 * tuni(s, 45u, ci, 0));
            let yy = select(TAPE_W - y, y, fromBottom);
            if (yy >= extent) { continue; }
            let reach = sstep(extent, extent * 0.8, yy);
            let w = 0.3 + 2.7 * pow(tuni(s, 46u, ci, 0), 1.5);
            let peak = (0.5 + 3.5 * pow(tuni(s, 47u, ci, 0), 1.5)) * (0.4 + 0.6 * U.creases);
            let dd = (off + yy * slant) / w;
            if (abs(dd) >= 4.0) { continue; }
            let profile = exp(-dd * dd) * (0.75 + 0.25 * cos(dd * 9.0));
            lift += peak * profile * reach;
            outp *= 1.0 - 0.3 * profile * reach;
        }
    }
    if (U.edge > 0.0) {
        for (var side = 0; side < 2; side++) {
            let k = u32(51 + side * 4);
            let yy = select(TAPE_W - y, y, side == 0);
            let c60 = tcell(p, 600);
            let stretch = noise1(s, k, c60.c, c60.f);
            let damaged = sstep(U.edge * 0.85, U.edge * 0.85 - 0.1, stretch);
            if (damaged <= 0.0) { continue; }
            let c20 = tcell(p, 200);
            let reach = 0.3 + 1.9 * U.edge * (0.5 + 0.5 * noise1(s, k + 1u, c20.c, c20.f));
            if (yy >= reach) { continue; }
            let c1 = tcell(p, 12);
            let crinkle = noise1(s, k + 2u, c1.c, c1.f);
            lift += damaged * U.edge * (1.0 + 2.5 * crinkle * crinkle) * pow(1.0 - yy / reach, 0.7);
        }
    }
    if (U.mold > 0.0) {
        let c = tcell(p, 40);
        let cy = i32(floor(y / 4.0));
        for (var j = -1; j <= 1; j++) {
            for (var i = -1; i <= 1; i++) {
                let ci = c.c + i;
                let cj = cy + j;
                let ycen = (f32(cj) + tuni(s, 63u, ci, cj)) * 4.0;
                if (ycen <= -1.0 || ycen >= TAPE_W + 1.0) { continue; }
                let edgeNear = 1.0 - min(1.0, min(abs(ycen), abs(TAPE_W - ycen)) / 6.3);
                if (tuni(s, 61u, ci, cj) >= min(0.95, U.mold * (0.3 + 1.3 * edgeNear))) { continue; }
                let ddx = tdx(p, ci, 40, tuni(s, 62u, ci, cj)) * 0.1;
                let ddy = ycen - y;
                let d = sqrt(ddx * ddx + ddy * ddy);
                let big = (0.35 + 2.0 * pow(tuni(s, 64u, ci, cj), 1.3)) * (0.6 + 0.4 * U.mold);
                if (d >= big * 1.4) { continue; }
                let turn = (atan2(ddy, ddx) / TAU + 0.5) * 6.0;
                let ti = i32(floor(turn));
                let a0 = tuni(s, 65u, ci * 7 + (ti % 6), cj);
                let a1 = tuni(s, 65u, ci * 7 + ((ti + 1) % 6), cj);
                let rr = big * (0.7 + 0.6 * (a0 + (a1 - a0) * sm(turn - f32(ti))));
                var dens = 1.0 - sstep(rr * 0.35, rr, d);
                if (dens <= 0.0) { continue; }
                let f3 = tcell(p, 3);
                let fy3 = y * 0.33 * 10.0;
                let gy = i32(floor(fy3));
                dens *= 0.55 + 0.45 * noise2(s, 66u, f3.c, f3.f, gy, fy3 - f32(gy));
                lift += dens * (0.5 + 2.5 * U.mold);
                outp *= 1.0 - 0.55 * dens;
            }
        }
    }
    if (U.vaseline > 0.0) {
        let sx = tcell(p, 600);
        if (tuni(s, 71u, sx.c, 0) < 0.2 + 0.8 * U.vaseline) {
            let a = 0.4 * tuni(s, 72u, sx.c, 0);
            let b = 0.6 + 0.4 * tuni(s, 73u, sx.c, 0);
            let taper = sstep(a, a + 0.05, sx.f) * sstep(b, b - 0.05, sx.f);
            if (taper > 0.0) {
                let c8 = tcell(p, 80);
                let yy = y * 5.0;
                let cy = i32(floor(yy));
                let streak = pow(noise2(s, 74u, c8.c, c8.f, cy, yy - f32(cy)), 1.5);
                film = U.vaseline * 1.8 * (0.25 + 0.75 * streak) * taper;
            }
        }
    }
    return TPt(lift, film, max(0.0, outp));
}

// ---- 1: record each line (one thread per row, along the line) ----
@compute @workgroup_size(64)
fn vcr_record(@builtin(global_invocation_id) gid: vec3<u32>) {
    let y = gid.x;
    if (y >= U.rows) { return; }
    let w = i32(U.width);
    var phase = TAU * tuni(U.seed ^ 0xA5A5u, U.field, i32(y), 1);
    var xPrev = 0.0;
    var ePrev = 0.0;
    for (var i = 0u; i < U.n; i++) {
        let u = (f32(i) + 0.5) * U.dt;
        var ire = 0.0;
        var c = vec2<f32>(0.0);
        if (u < SYNC_END) {
            ire = -40.0;
        } else if (u < ACT_S) {
            if (u >= BURST_S && u < BURST_E) { c = BURST_DIR * U.burstAmp; }
        } else if (u < ACT_S + ACT_L) {
            let xs = (u - ACT_S) / U.usPerPixel - 0.5;
            let x0 = floor(xs);
            let f = xs - x0;
            let ix = i32(x0);
            let a = textureLoad(src, vec2<i32>(clamp(ix, 0, w - 1), i32(y)), 0).rgb;
            let b = textureLoad(src, vec2<i32>(clamp(ix + 1, 0, w - 1), i32(y)), 0).rgb;
            let q = rgb2yiq(mix(a, b, f));
            ire = 7.5 + 92.5 * q.x;
            c = q.yz;
        }
        let e = U.emB0 * ire + U.emB1 * xPrev - U.emA1 * ePrev;
        xPrev = ire;
        ePrev = e;
        let ec = clamp(e, U.darkClip, U.whiteClip);
        let mhz = 3.4 + (ec + 40.0) / 140.0;
        phase += TAU * mhz * U.dt;
        phase -= TAU * floor(phase / TAU);
        let ang = U.cuStep * f32(i);
        let under = U.chromaLevel * (c.x * cos(ang) - c.y * sin(ang));
        rf[y * U.n + i] = cos(phase) + under;
    }
}

// ---- 2: the tape under each segment, across the head's width ----
@compute @workgroup_size(64)
fn vcr_tape(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= U.segs || gid.y >= U.rows) { return; }
    let L = lines[gid.y];
    let u = (f32(gid.x) + 0.5) * 16.0 * U.dt;
    let along = L.along0 + u / U.lineUS * U.lineLength;
    var lift = 0.0;
    var film = 0.0;
    var outp = 0.0;
    for (var k = 0; k < 4; k++) {
        let across = (f32(k) - 1.5) * 0.25 * U.pitch;
        let p = TPos(L.originBase, L.originOffset + (along * U.cosA - across * U.sinA) * 10.0,
                     U.trackStart + along * U.sinA + across * U.cosA);
        let t = tape_at(p);
        lift += t.lift;
        film += t.film;
        outp += t.outp;
    }
    lift *= 0.25;
    film *= 0.25;
    outp *= 0.25;
    let d = lift + L.spacing + max(film, L.grease);
    seg[gid.y * U.segs + gid.x] = vec2<f32>(d, outp * L.gain);
}

// ---- 3: what is magnetized under the head, and how far away ----
@compute @workgroup_size(64)
fn vcr_magnet(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= U.n || gid.y >= U.rows) { return; }
    let sf = (f32(gid.x) + 0.5) / 16.0 - 0.5;
    let i0 = clamp(i32(floor(sf)), 0, i32(U.segs) - 1);
    let i1 = min(i0 + 1, i32(U.segs) - 1);
    let t = clamp(sf - f32(i0), 0.0, 1.0);
    let a = seg[gid.y * U.segs + u32(i0)];
    let b = seg[gid.y * U.segs + u32(i1)];
    let v = mix(a, b, t);
    let k = gid.y * U.n + gid.x;
    mag[k] = vec2<f32>(rf[k] * v.y, v.x);
}

// ---- 4: the head reads it: spacing and gap losses, plus noise ----
@compute @workgroup_size(64)
fn vcr_play(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= U.n || gid.y >= U.rows) { return; }
    let row = gid.y * U.n;
    let i = i32(gid.x);
    let d = mag[row + u32(i)].y;
    let lv = sqrt(clamp(d / U.maxSpacing, 0.0, 1.0)) * f32(U.levels - 1u);
    let l0 = min(i32(floor(lv)), i32(U.levels) - 2);
    let t = lv - f32(l0);
    let R = i32(U.reach);
    let taps = u32(2 * R + 1);
    let k0 = (lines[gid.y].head * U.levels + u32(l0)) * taps;
    let k1 = k0 + taps;
    var acc = 0.0;
    let last = i32(U.n) - 1;
    for (var k = -R; k <= R; k++) {
        let j = clamp(i - k, 0, last);
        let w = mix(bank[k0 + u32(k + R)], bank[k1 + u32(k + R)], t);
        acc += w * mag[row + u32(j)].x;
    }
    acc += U.noise * gaussn(U.seed ^ 0x51u, U.field, i, i32(gid.y));
    pb[row + u32(i)] = acc;
}

// ---- 5: the FM band as an analytic signal ----
@compute @workgroup_size(64)
fn vcr_fmband(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= U.n || gid.y >= U.rows) { return; }
    let row = gid.y * U.n;
    let i = i32(gid.x);
    let R = i32(U.fmReach);
    let last = i32(U.n) - 1;
    var acc = vec2<f32>(0.0);
    for (var k = -R; k <= R; k++) {
        let j = clamp(i - k, 0, last);
        acc += taps[u32(k + R)] * pb[row + u32(j)];
    }
    zb[row + u32(i)] = acc;
}

fn biquad(s: ptr<function, vec4<f32>>, x: f32, b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> f32 {
    let v = *s;
    let y = b0 * x + b1 * v.x + b2 * v.y - a1 * v.z - a2 * v.w;
    *s = vec4<f32>(x, v.x, y, v.z);
    return y;
}

// ---- 6: the deck's electronics, along each line ----
@compute @workgroup_size(64)
fn vcr_line(@builtin(global_invocation_id) gid: vec3<u32>) {
    let y = gid.x;
    if (y >= U.rows) { return; }
    let row = y * U.n;
    let N = U.n;
    // The detector follows the envelope's recent peak (~30 µs decay), so it
    // reacts to sudden drops, not to a uniformly weak signal.
    var prev = zb[row];
    var env = length(prev);
    var refl = env;
    for (var i = 0u; i < min(N, 120u); i++) { refl = max(refl, length(zb[row + i])); }
    var flagged = false;
    var hold = 0;
    for (var i = 0u; i < N; i++) {
        let c = zb[row + i];
        let dphi = atan2(prev.x * c.y - prev.y * c.x, prev.x * c.x + prev.y * c.y);
        prev = c;
        let mhz = clamp(dphi / (TAU * U.dt), 1.0, 7.5);
        luma[row + i] = (mhz - 3.4) * 140.0 - 40.0;
        env += 0.12 * (length(c) - env);
        refl = select(refl * 0.99885, refl + 0.05 * (env - refl), env > refl);
        let on = max(0.02, U.docOn * refl);
        let off = max(0.03, U.docOff * refl);
        if (flagged) {
            if (env > off) { hold -= 1; if (hold <= 0) { flagged = false; } } else { hold = 14; }
        } else if (env < on) { flagged = true; hold = 14; }
        chroma[row + i] = vec2<f32>(select(0.0, 1.0, flagged), 0.0);
    }
    var s = vec4<f32>(luma[row]);
    for (var i = 0u; i < N; i++) { luma[row + i] = biquad(&s, luma[row + i], U.lb0, U.lb1, U.lb2, U.la1, U.la2); }
    s = vec4<f32>(luma[row + N - 1u]);
    for (var i = i32(N) - 1; i >= 0; i--) { luma[row + u32(i)] = biquad(&s, luma[row + u32(i)], U.lb0, U.lb1, U.lb2, U.la1, U.la2); }
    var xp = luma[row];
    var yp = luma[row];
    for (var i = 0u; i < N; i++) {
        let x = luma[row + i];
        let v = U.deB0 * x + U.deB1 * xp - U.deA1 * yp;
        xp = x;
        yp = v;
        // Flagged samples are stored as v + 10000 (decoded in vcr_out).
        luma[row + i] = select(v, v + 10000.0, chroma[row + i].x > 0.5);
    }
    for (var i = 0u; i < N; i++) {
        let a = U.cuStep * f32(i);
        chroma[row + i] = pb[row + i] * vec2<f32>(cos(a), -sin(a));
    }
    for (var round = 0; round < 2; round++) {
        var sr = vec4<f32>(0.0);
        var si = vec4<f32>(0.0);
        for (var i = 0u; i < N; i++) {
            let c = chroma[row + i];
            chroma[row + i] = vec2<f32>(biquad(&sr, c.x, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2),
                                        biquad(&si, c.y, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2));
        }
        sr = vec4<f32>(0.0);
        si = vec4<f32>(0.0);
        for (var i = i32(N) - 1; i >= 0; i--) {
            let c = chroma[row + u32(i)];
            chroma[row + u32(i)] = vec2<f32>(biquad(&sr, c.x, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2),
                                             biquad(&si, c.y, U.cb0, U.cb1, U.cb2, U.ca1, U.ca2));
        }
    }
    let k = 2.0 / U.chromaLevel;
    var b = vec2<f32>(0.0);
    var cnt = 0;
    for (var i = 0u; i < N; i++) {
        let u = (f32(i) + 0.5) * U.dt;
        let c = chroma[row + i] * k;
        chroma[row + i] = c;
        if (u >= BURST_S + 0.3 && u < BURST_E - 0.3) { b += c; cnt++; }
    }
    burst[y] = b / f32(max(cnt, 1));
}

// ---- 7: ACC, APC and color killer, down the field ----
@compute @workgroup_size(1)
fn vcr_acc(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x != 0u) { return; }
    let refb = BURST_DIR * U.burstAmp;
    let nominal = U.burstAmp;
    var gain = 1.0;
    var phase = 0.0;
    var killer = 1.0;
    var on = true;
    for (var y = 0u; y < U.rows; y++) {
        let b = burst[y];
        let m = length(b);
        let err = atan2(refb.x * b.y - refb.y * b.x, refb.x * b.x + refb.y * b.y);
        if (m > 0.08 * nominal) { phase += 0.35 * (err - phase); }
        gain += 0.3 * (nominal / max(m, 0.05 * nominal) - gain);
        gain = clamp(gain, 0.3, 20.0);
        // The killer cuts chroma once the burst is ~26 dB down.
        killer += 0.2 * (clamp(m / nominal, 0.0, 1.0) - killer);
        if (on && killer < 0.05) { on = false; } else if (!on && killer > 0.08) { on = true; }
        color[y] = vec4<f32>(cos(-phase), sin(-phase), select(0.0, gain, on), 0.0);
    }
}

// ---- 8: back to pixels, with dropout compensation ----
@compute @workgroup_size(64)
fn vcr_out(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= U.width || gid.y >= U.rows) { return; }
    let u0 = ACT_S + f32(gid.x) * U.usPerPixel;
    let n0 = i32(floor(u0 / U.dt));
    var n1 = max(n0 + 1, i32(floor((u0 + U.usPerPixel) / U.dt)));
    n1 = min(n1, i32(U.n));
    var ire = 0.0;
    var c = vec2<f32>(0.0);
    for (var i = n0; i < n1; i++) {
        var v = luma[gid.y * U.n + u32(i)];
        if (v > 5000.0) {
            v -= 10000.0;
            // With compensation the deck replays the line before from its
            // one-line delay — that line's own output, so a tall flaw
            // repeats one line down several.
            if (U.doc != 0u) {
                for (var k = 1; k <= 64 && i32(gid.y) - k >= 0; k++) {
                    let w = luma[u32(i32(gid.y) - k) * U.n + u32(i)];
                    if (w < 5000.0) { v = w; break; }
                    v = w - 10000.0;
                }
            }
        }
        ire += v;
        c += chroma[gid.y * U.n + u32(i)];
    }
    let cnt = f32(n1 - n0);
    ire /= cnt;
    c /= cnt;
    let rc = color[gid.y];
    let iq = vec2<f32>(c.x * rc.x - c.y * rc.y, c.x * rc.y + c.y * rc.x) * rc.z;
    let yiq = vec3<f32>((ire - 7.5) / 92.5, iq.x, iq.y);
    textureStore(dst, vec2<i32>(gid.xy), vec4<f32>(clamp(yiq2rgb(yiq), vec3<f32>(0.0), vec3<f32>(1.0)), 1.0));
}
