//! The size the CRT shader renders at, and how big the preview is shown: a
//! port of the Mac's `PreviewScaler` (PreviewScaling.swift), same rules and
//! the same tests.
//!
//! 1. One picture, however it is looked at. CRT shaders draw scanlines and
//!    masks in output pixels, so the multiple they render at *is* the look:
//!    at 1 row a line there is no room for a scanline, and a mask's stripes
//!    are twice as coarse against the picture at 3× as at 6×. So the shader
//!    renders at one multiple that depends only on the picture going into it
//!    (`render_multiple`): the same in any window, with integer scale and
//!    without, and in every export (`export::render_size`). The preview and
//!    an export are that one render scaled to the window or the file by the
//!    same filter. (Through 0.29.1 the preview rendered at 6× and up, by
//!    window size, and an export straight at its own size.)
//! 2. Integer scale must snap: every line gets the same whole number of
//!    screen rows, so the picture steps between sizes and is letterboxed.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PreviewPlan {
    /// What the chain renders.
    pub render_width: u32,
    pub render_height: u32,
    /// What's shown: a whole multiple of the chain input with integer
    /// scale (letterboxed), else the drawable.
    pub display_width: u32,
    pub display_height: u32,
    /// display ÷ chain input; 0 when not integer-scaled.
    pub display_multiple: u32,
    /// render ÷ chain input.
    pub render_multiple: u32,
}

impl PreviewPlan {
    pub fn needs_downsample(&self) -> bool {
        self.render_width != self.display_width || self.render_height != self.display_height
    }
}

/// Fewest output rows per line the chain may render at (the glow shaders
/// clip 21% of the frame at 1, 6% at 2, 0.55% at 4, none at 6).
pub const MIN_RENDER_MULTIPLE: u32 = 6;
/// The largest render, on its long edge.
pub const MAX_LONG_EDGE: u32 = 4096;
/// The render's long edge is at least this, when the multiple allows it: a
/// 1920 export (the default) of a small picture is then scaled down from
/// the render, never up (256 wide renders at 8×, 160 at 12×).
pub const MIN_RENDER_LONG_EDGE: u32 = 1920;

/// The picture the CRT shader is given, for one this size coming out of the
/// Downscale (or straight from the source, with the Downscale off): itself,
/// unless it is too large to render at two rows a line within the budget —
/// then the largest of its shape that can be (2048 on its long edge). A
/// shader drawing scanlines needs at least two rows for each line it is
/// given: at one it draws none, only its mask, and the aperture shader
/// divides by the whole number of rows a line — black below one, and at
/// exactly one for line counts whose reciprocal rounds down (2544). The
/// engine scales the picture to this size on its way into the shader.
pub fn shader_input(size: (u32, u32)) -> (u32, u32) {
    shader_input_within(size, MAX_LONG_EDGE)
}

pub fn shader_input_within(size: (u32, u32), max_long_edge: u32) -> (u32, u32) {
    let long = size.0.max(size.1);
    if size.0 == 0 || size.1 == 0 || long * 2 <= max_long_edge {
        return size;
    }
    let scale = (max_long_edge / 2) as f64 / long as f64;
    (((size.0 as f64 * scale).round() as u32).max(1), ((size.1 as f64 * scale).round() as u32).max(1))
}

/// The multiple of the picture going into the CRT shader (`shader_input`)
/// that the shader renders at, for the preview and exports alike: the
/// smallest even one that reaches both floors, stepped down to fit the
/// texture budget (a 1024-wide picture renders at 4×, a 1920-wide one at
/// 2×) — never under 2. Even, because at odd multiples the glow shaders'
/// half-texel scanline offset jitters line spacing.
pub fn render_multiple(input: (u32, u32)) -> u32 {
    render_multiple_within(input, MIN_RENDER_MULTIPLE, MAX_LONG_EDGE)
}

pub fn render_multiple_within(input: (u32, u32), min_render: u32, max_long_edge: u32) -> u32 {
    let long = input.0.max(input.1).max(1);
    let mut m = min_render.max(2).max(MIN_RENDER_LONG_EDGE.div_ceil(long));
    if m % 2 == 1 {
        m += 1;
    }
    while m > 2 && long * m > max_long_edge {
        m -= 2;
    }
    m
}

pub fn plan(input: (u32, u32), drawable: (u32, u32), integer_scale: bool) -> PreviewPlan {
    plan_with(input, drawable, integer_scale, MIN_RENDER_MULTIPLE, MAX_LONG_EDGE)
}

pub fn plan_with(input: (u32, u32), drawable: (u32, u32), integer_scale: bool, min_render: u32, max_long_edge: u32) -> PreviewPlan {
    let (dw, dh) = (drawable.0.max(1), drawable.1.max(1));
    let (iw, ih) = input;
    let fill_at_drawable = || {
        let scale = (max_long_edge as f64 / dw.max(dh) as f64).min(1.0);
        PreviewPlan {
            render_width: ((dw as f64 * scale) as u32).max(64),
            render_height: ((dh as f64 * scale) as u32).max(64),
            display_width: dw,
            display_height: dh,
            display_multiple: 0,
            render_multiple: 0,
        }
    };
    if iw == 0 || ih == 0 {
        return fill_at_drawable();
    }
    // What the shader is given (the picture, or a smaller one when it is too
    // large to render), and the one render multiple for it, whatever the
    // window.
    let (iw, ih) = shader_input_within((iw, ih), max_long_edge);
    let rk = render_multiple_within((iw, ih), min_render, max_long_edge);
    if !integer_scale {
        return PreviewPlan {
            render_width: iw * rk,
            render_height: ih * rk,
            display_width: dw,
            display_height: dh,
            display_multiple: 0,
            render_multiple: rk,
        };
    }
    // Largest whole multiple that fits, preferring even ones (at odd ones the
    // glow shaders' half-texel scanline offset jitters line spacing).
    let mut k = (dw / iw).min(dh / ih).max(1);
    if k > 1 && k % 2 == 1 {
        k -= 1;
    }
    if iw * k > dw || ih * k > dh {
        // Too small for one whole copy: fit instead, keeping the shader's rows.
        let scale = (dw as f64 / iw as f64).min(dh as f64 / ih as f64);
        return PreviewPlan {
            render_width: iw * rk,
            render_height: ih * rk,
            display_width: ((iw as f64 * scale).round() as u32).max(1),
            display_height: ((ih as f64 * scale).round() as u32).max(1),
            display_multiple: 0,
            render_multiple: rk,
        };
    }
    PreviewPlan {
        render_width: iw * rk,
        render_height: ih * rk,
        display_width: iw * k,
        display_height: ih * k,
        display_multiple: k,
        render_multiple: rk,
    }
}

/// How far the picture can be panned at `zoom`, as a share of its own size
/// either way from center, so its edge never comes inside the view's (the
/// Mac's `PreviewGeometry.panLimit`). `view` is the preview area's extent
/// along one axis, `picture` the picture's at 100%. Zoomed in, the picture
/// grows past its fit rectangle into the rest of the view; while it's still
/// smaller than the view along an axis it stays centered there.
pub fn pan_limit(zoom: f32, view: f32, picture: f32) -> f32 {
    if !(zoom > 0.0 && picture > 0.0) {
        return 0.0;
    }
    (0.5 - view / (2.0 * picture * zoom)).max(0.0)
}

#[cfg(test)]
mod tests {
    //! The Mac's PreviewScalingTests, ported.
    use super::*;

    const INPUTS: [(u32, u32); 3] = [(320, 320), (320, 240), (256, 224)];
    const DRAWABLES: [(u32, u32); 8] =
        [(632, 632), (900, 700), (1132, 1132), (1346, 1346), (1532, 1532), (2000, 1400), (2560, 1600), (3000, 2200)];

    #[test]
    fn display_is_a_whole_multiple_and_never_overflows() {
        for i in INPUTS {
            for d in DRAWABLES {
                let p = plan(i, d, true);
                assert!(p.display_width <= d.0 && p.display_height <= d.1);
                if p.display_multiple > 0 {
                    assert_eq!(p.display_width, i.0 * p.display_multiple);
                    assert_eq!(p.display_height, i.1 * p.display_multiple);
                }
            }
        }
    }

    #[test]
    fn display_size_steps_rather_than_tracking_the_window() {
        let mut seen = std::collections::BTreeSet::new();
        for dw in (700..=2600).step_by(7) {
            let p = plan((320, 320), (dw, dw), true);
            assert_eq!(p.display_width % 320, 0);
            seen.insert(p.display_width);
        }
        assert!(seen.len() <= 8, "{seen:?}");
    }

    #[test]
    fn toggling_integer_scale_changes_the_displayed_size() {
        assert_eq!(plan((320, 320), (1346, 1346), false).display_width, 1346);
        assert_eq!(plan((320, 320), (1346, 1346), true).display_width, 1280);
    }

    #[test]
    fn render_meets_the_floor_within_the_budget() {
        for d in DRAWABLES {
            assert!(plan((320, 320), d, true).render_multiple >= MIN_RENDER_MULTIPLE);
            for i in [(320, 320), (1024, 1024), (1920, 1080), (3840, 2160)] {
                let p = plan(i, d, true);
                assert!(p.render_width.max(p.render_height) <= 4096, "{i:?} at {d:?}");
            }
        }
    }

    /// The multiple the shader renders at is the look, so it depends on the
    /// picture alone: the same in every window, with integer scale and
    /// without.
    #[test]
    fn the_render_depends_only_on_the_picture() {
        for i in INPUTS.into_iter().chain([(256, 192), (640, 480), (1024, 768), (1920, 1080)]) {
            let expected = render_multiple(i);
            for d in DRAWABLES {
                for integer in [true, false] {
                    let p = plan(i, d, integer);
                    assert_eq!(p.render_multiple, expected, "{i:?} in {d:?}, integer {integer}");
                    assert_eq!((p.render_width, p.render_height), (i.0 * expected, i.1 * expected));
                }
            }
        }
        assert_eq!(render_multiple((320, 240)), 6);
        assert_eq!(render_multiple((640, 480)), 6);
        assert_eq!(render_multiple((256, 192)), 8);
        assert_eq!(render_multiple((160, 120)), 12);
        assert_eq!(render_multiple((1024, 768)), 4);
        assert_eq!(render_multiple((1920, 1080)), 2);
    }

    /// An export renders the shader at the size the preview does, whatever
    /// size the file is.
    #[test]
    fn exports_render_at_the_previews_size() {
        for i in [(256u32, 192u32), (320, 240), (640, 480), (1024, 768), (1904, 2544)] {
            let p = plan(i, (1500, 1100), true);
            for long in [480u32, 1280, 1920, 3840] {
                let target = if i.0 >= i.1 { (long, long * i.1 / i.0) } else { (long * i.0 / i.1, long) };
                assert_eq!(crate::export::render_size(i, target), (p.render_width, p.render_height), "{i:?} into {target:?}");
            }
        }
    }

    /// A shader that draws scanlines needs at least two rows for each line
    /// it is given: a picture too large for that within the budget reaches
    /// the shader smaller.
    #[test]
    fn the_shader_always_gets_at_least_two_rows_a_line() {
        for i in [(1904u32, 2544u32), (3840, 2160), (2049, 100), (6000, 4000), (4096, 4096)] {
            let given = shader_input(i);
            assert!(given.0.max(given.1) * 2 <= MAX_LONG_EDGE);
            assert!((given.0 as f64 / given.1 as f64 - i.0 as f64 / i.1 as f64).abs() < 0.01);
            for integer in [true, false] {
                let p = plan(i, (1500, 1100), integer);
                assert!(p.render_multiple >= 2 && p.render_multiple % 2 == 0);
                assert_eq!(p.render_height, given.1 * p.render_multiple);
                assert!(p.render_width.max(p.render_height) <= MAX_LONG_EDGE);
            }
        }
        assert_eq!(shader_input((2048, 1536)), (2048, 1536));
        assert_eq!(shader_input((640, 480)), (640, 480));
    }

    #[test]
    fn odd_multiples_step_back_and_tiny_windows_fit() {
        assert_eq!(plan((320, 320), (1600, 1600), true).display_multiple, 4);
        let p = plan((320, 320), (200, 200), true);
        assert_eq!(p.display_multiple, 0);
        assert!(p.display_width <= 200 && p.display_width > 0);
        assert!(p.render_multiple >= MIN_RENDER_MULTIPLE);
    }

    #[test]
    fn a_zoomed_picture_pans_until_its_edge_meets_the_views() {
        // A picture as wide as the view: the old rule, half of what's off screen.
        assert!((pan_limit(2.0, 800.0, 800.0) - 0.25).abs() < 1e-6);
        assert_eq!(pan_limit(1.0, 800.0, 800.0), 0.0);
        // A tall picture in a wide view (600 of 1000 across): centered until
        // it's zoomed past the view's width, then it pans.
        assert_eq!(pan_limit(1.5, 1000.0, 600.0), 0.0);
        assert!((pan_limit(2.5, 1000.0, 600.0) - (0.5 - 1000.0 / 3000.0)).abs() < 1e-6);
        // At the limit the picture's edge is exactly at the view's.
        let (zoom, view, picture) = (3.0f32, 1000.0f32, 600.0f32);
        let size = picture * zoom;
        let left = view / 2.0 - (0.5 - pan_limit(zoom, view, picture)) * size;
        assert!(left.abs() < 1e-3, "{left}");
    }

    #[test]
    fn without_integer_scale_the_image_fills() {
        for d in DRAWABLES {
            let p = plan((320, 320), d, false);
            assert_eq!((p.display_width, p.display_height), d);
            assert!(p.render_multiple >= MIN_RENDER_MULTIPLE);
            assert_eq!(p.render_multiple % 2, 0);
            assert_eq!(p.render_width, 320 * p.render_multiple);
            assert!(p.needs_downsample());
        }
    }
}
