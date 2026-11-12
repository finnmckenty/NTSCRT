// Screen Loop's kernels: ports of Howlaround.swift's Metal source.

struct CameraUniforms {
    axis_x: vec4<f32>,
    axis_y: vec4<f32>,
    normal: vec4<f32>,
    center: vec4<f32>,
    balance: vec4<f32>,
    counter_rect: vec4<f32>,
    params: vec4<f32>,   // aspect, zoom, brightness, contrast
    params2: vec4<f32>,  // hue cos, hue sin, exposure, TV in view
    key: vec4<f32>,      // key level, invert
};

@group(0) @binding(0) var scene: texture_2d<f32>;
@group(0) @binding(1) var tv: texture_2d<f32>;
@group(0) @binding(2) var counter: texture_2d<f32>;
@group(0) @binding(3) var out: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(4) var<uniform> u: CameraUniforms;
@group(0) @binding(5) var linear_clamp: sampler;

// What the camera sees at each pixel: the room, or (where the ray hits the
// TV's screen) the TV's picture, as bright and as tinted as the camera sees it.
@compute @workgroup_size(8, 8)
fn howl_camera(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = textureDimensions(out);
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    let W = f32(size.x);
    let H = f32(size.y);
    let src = textureLoad(scene, vec2<i32>(gid.xy), 0).rgb;
    var c = src;
    let aspect = u.params.x;
    let zoom = u.params.y;
    let uv = (vec2<f32>(gid.xy) + 0.5) / vec2<f32>(W, H);
    if (u.params2.w > 0.5) {
        let d = vec3<f32>((uv.x - 0.5) * aspect, uv.y - 0.5, 1.0);
        let n = u.normal.xyz;
        let denom = dot(d, n);
        if (abs(denom) > 1e-6) {
            let t = dot(u.center.xyz, n) / denom;
            if (t > 0.0) {
                let p = d * t - u.center.xyz;
                let sx = dot(p, u.axis_x.xyz) / (zoom * aspect) + 0.5;
                let sy = dot(p, u.axis_y.xyz) / zoom + 0.5;
                // Anti-aliased screen edge, about a pixel wide.
                let ex = min(sx, 1.0 - sx) * zoom * W;
                let ey = min(sy, 1.0 - sy) * zoom * H;
                let cover = clamp(min(ex, ey) + 0.5, 0.0, 1.0);
                if (cover > 0.0) {
                    var s = textureSampleLevel(tv, linear_clamp, vec2<f32>(sx, sy), 0.0).rgb;
                    s *= u.params.z;
                    s = (s - 0.5) * u.params.w + 0.5;
                    s *= u.balance.rgb;
                    let y = dot(s, vec3<f32>(0.299, 0.587, 0.114));
                    let i = dot(s, vec3<f32>(0.596, -0.274, -0.322));
                    let q = dot(s, vec3<f32>(0.211, -0.523, 0.312));
                    let i2 = i * u.params2.x - q * u.params2.y;
                    let q2 = i * u.params2.y + q * u.params2.x;
                    s = vec3<f32>(y + 0.956 * i2 + 0.621 * q2,
                                  y - 0.272 * i2 - 0.647 * q2,
                                  y - 1.106 * i2 + 1.703 * q2);
                    c = mix(c, clamp(s, vec3<f32>(0.0), vec3<f32>(1.0)), cover);
                }
            }
        }
    }
    // The mixer's luma key: your picture over the camera's wherever it's
    // brighter than the key level (darker, inverted), with a soft edge.
    if (u.key.x > 0.0) {
        var y = dot(src, vec3<f32>(0.299, 0.587, 0.114));
        if (u.key.y > 0.5) { y = 1.0 - y; }
        let level = 1.0 - u.key.x;
        c = mix(c, src, smoothstep(level - 0.06, level + 0.06, y));
    }
    c *= u.params2.z;
    let r = u.counter_rect;
    if (r.z > r.x && uv.x >= r.x && uv.x <= r.z && uv.y >= r.y && uv.y <= r.w) {
        // Premultiplied white figures with a dark edge.
        let t = textureSampleLevel(counter, linear_clamp, (uv - r.xy) / (r.zw - r.xy), 0.0);
        c = c * (1.0 - t.a) + t.rgb;
    }
    textureStore(out, vec2<i32>(gid.xy), vec4<f32>(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0));
}

struct BlurUniforms { dir: vec2<f32>, sigma: f32, radius: i32 };

@group(0) @binding(0) var blur_src: texture_2d<f32>;
@group(0) @binding(1) var blur_dst: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var<uniform> b: BlurUniforms;

@compute @workgroup_size(8, 8)
fn howl_blur(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = textureDimensions(blur_dst);
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    var acc = vec4<f32>(0.0);
    var wsum = 0.0;
    let step = vec2<i32>(b.dir);
    for (var k = -b.radius; k <= b.radius; k++) {
        let w = exp(-0.5 * f32(k * k) / (b.sigma * b.sigma));
        let p = clamp(vec2<i32>(gid.xy) + step * k, vec2<i32>(0), vec2<i32>(size) - 1);
        acc += textureLoad(blur_src, p, 0) * w;
        wsum += w;
    }
    textureStore(blur_dst, vec2<i32>(gid.xy), acc / wsum);
}
