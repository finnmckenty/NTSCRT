// Port of Downscaler.swift's downscale_area Metal kernel (box average of
// every source pixel each destination pixel covers), same float math.
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
