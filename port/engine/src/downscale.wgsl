// Ports of Downscaler.swift's Metal kernels, with the same float math:
// nearest (Chunky) and area (Smooth, a box average of every source pixel
// each destination pixel covers).
struct Dims { sw: u32, sh: u32, dw: u32, dh: u32 };
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var dst: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var<uniform> d: Dims;

@compute @workgroup_size(8, 8)
fn downscale_area(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= d.dw || gid.y >= d.dh) { return; }
    let sx0 = f32(gid.x)      * f32(d.sw) / f32(d.dw);
    let sx1 = f32(gid.x + 1u) * f32(d.sw) / f32(d.dw);
    let sy0 = f32(gid.y)      * f32(d.sh) / f32(d.dh);
    let sy1 = f32(gid.y + 1u) * f32(d.sh) / f32(d.dh);
    let x0 = i32(floor(sx0)); let x1 = i32(ceil(sx1));
    let y0 = i32(floor(sy0)); let y1 = i32(ceil(sy1));
    var acc = vec4<f32>(0.0);
    var wsum = 0.0;
    for (var y = y0; y < y1; y++) {
        let fy = clamp(min(f32(y) + 1.0, sy1) - max(f32(y), sy0), 0.0, 1.0);
        let cy = clamp(y, 0, i32(d.sh) - 1);
        for (var x = x0; x < x1; x++) {
            let fx = clamp(min(f32(x) + 1.0, sx1) - max(f32(x), sx0), 0.0, 1.0);
            let cx = clamp(x, 0, i32(d.sw) - 1);
            let w = fx * fy;
            acc += textureLoad(src, vec2<i32>(cx, cy), 0) * w;
            wsum += w;
        }
    }
    textureStore(dst, vec2<i32>(gid.xy), acc / max(wsum, 1e-6));
}

// Metal's nearest sampler at the destination pixel's center: the source
// texel containing uv, clamped to the edge.
@compute @workgroup_size(8, 8)
fn downscale_nearest(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= d.dw || gid.y >= d.dh) { return; }
    let uv = (vec2<f32>(gid.xy) + 0.5) / vec2<f32>(f32(d.dw), f32(d.dh));
    let texel = clamp(vec2<i32>(floor(uv * vec2<f32>(f32(d.sw), f32(d.sh)))),
                      vec2<i32>(0), vec2<i32>(i32(d.sw) - 1, i32(d.sh) - 1));
    textureStore(dst, vec2<i32>(gid.xy), textureLoad(src, texel, 0));
}

// ---------- separable, ratio-scaled filters (Nearest+, Bilinear, Bicubic, Lanczos) ----------
// Two passes, as on the Mac: horizontal (sw × sh → dw × sh) into a scratch
// texture, then vertical (dw × sh → dw × dh). `t` is in filter space (source
// distance ÷ the downscale ratio), so each filter keeps its natural support.

fn w_nearestaa(t: f32) -> f32 { return exp(t * t * -4.0816); }
fn w_bilinear(t: f32) -> f32 { return max(0.0, 1.0 - abs(t)); }
fn w_bicubic(t: f32) -> f32 {   // Mitchell-Netravali B = C = 1/3
    let x = abs(t);
    let B = 1.0 / 3.0; let C = 1.0 / 3.0;
    let x2 = x * x; let x3 = x2 * x;
    if (x < 1.0) {
        return ((12.0 - 9.0 * B - 6.0 * C) * x3 + (-18.0 + 12.0 * B + 6.0 * C) * x2 + (6.0 - 2.0 * B)) * (1.0 / 6.0);
    }
    if (x < 2.0) {
        return ((-B - 6.0 * C) * x3 + (6.0 * B + 30.0 * C) * x2 + (-12.0 * B - 48.0 * C) * x + (8.0 * B + 24.0 * C)) * (1.0 / 6.0);
    }
    return 0.0;
}
fn sinc(x: f32) -> f32 {
    if (abs(x) < 1e-6) { return 1.0; }
    let xp = x * 3.14159265358979;
    return sin(xp) / xp;
}
fn w_lanczos(t: f32) -> f32 {
    if (abs(t) >= 3.0) { return 0.0; }
    return sinc(t) * sinc(t / 3.0);
}

// kind: 0 nearest+, 1 bilinear, 2 bicubic, 3 lanczos
struct Pass { sw: u32, sh: u32, dw: u32, dh: u32, kind: u32, vertical: u32, _p0: u32, _p1: u32 };
@group(0) @binding(0) var psrc: texture_2d<f32>;
@group(0) @binding(1) var pdst: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var<uniform> pp: Pass;

fn weight(f: u32, t: f32) -> f32 {
    switch (f) {
        case 0u: { return w_nearestaa(t); }
        case 1u: { return w_bilinear(t); }
        case 2u: { return w_bicubic(t); }
        default: { return w_lanczos(t); }
    }
}
fn radius(f: u32) -> f32 {
    switch (f) {
        case 2u: { return 2.0; }
        case 3u: { return 3.0; }
        default: { return 1.0; }
    }
}

@compute @workgroup_size(8, 8)
fn downscale_separable(@builtin(global_invocation_id) gid: vec3<u32>) {
    var limit_w = pp.dw; var limit_h = pp.sh;
    if (pp.vertical == 1u) { limit_h = pp.dh; }
    if (gid.x >= limit_w || gid.y >= limit_h) { return; }
    var n_src = pp.sw; var n_dst = pp.dw; var pos = gid.x;
    if (pp.vertical == 1u) { n_src = pp.sh; n_dst = pp.dh; pos = gid.y; }
    let scale = max(1.0, f32(n_src) / f32(n_dst));
    let center = (f32(pos) + 0.5) * f32(n_src) / f32(n_dst) - 0.5;
    let support = radius(pp.kind) * scale;
    let lo = i32(ceil(center - support));
    let hi = i32(floor(center + support));
    var acc = vec4<f32>(0.0);
    var wsum = 0.0;
    for (var i = lo; i <= hi; i++) {
        let w = weight(pp.kind, (f32(i) - center) / scale);
        let c = clamp(i, 0, i32(n_src) - 1);
        var p = vec2<i32>(c, i32(gid.y));
        if (pp.vertical == 1u) { p = vec2<i32>(i32(gid.x), c); }
        acc += textureLoad(psrc, p, 0) * w;
        wsum += w;
    }
    textureStore(pdst, vec2<i32>(gid.xy), acc / max(wsum, 1e-6));
}
