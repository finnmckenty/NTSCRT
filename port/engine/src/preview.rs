//! How big the preview renders and how big it's shown: a port of the Mac's
//! `PreviewScaler` (PreviewScaling.swift), same rules and the same tests.
//!
//! Two requirements pull against each other:
//! 1. The look must not depend on the window. CRT shaders draw scanlines and
//!    masks in output pixels, so the multiple they render at *is* the look;
//!    below about 6 rows per line the glow shaders clip and scanlines vanish.
//!    So the chain renders at a whole multiple of at least 6.
//! 2. Integer scale must snap: every line gets the same whole number of
//!    screen rows, so the picture steps between sizes and is letterboxed.
//!
//! Both hold by rendering at a whole multiple that is itself a whole multiple
//! of the displayed one, and box-filtering down to the display size.

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
pub const MAX_LONG_EDGE: u32 = 4096;

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
    if !integer_scale {
        let mut rk = render_multiple(1, iw, ih, min_render, max_long_edge);
        if rk > 1 && rk % 2 == 1 {
            rk -= 1; // odd multiples jitter the glow shaders
        }
        if iw.max(ih) * rk > max_long_edge {
            return fill_at_drawable();
        }
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
        let rk = render_multiple(1, iw, ih, min_render, max_long_edge);
        return PreviewPlan {
            render_width: iw * rk,
            render_height: ih * rk,
            display_width: ((iw as f64 * scale).round() as u32).max(1),
            display_height: ((ih as f64 * scale).round() as u32).max(1),
            display_multiple: 0,
            render_multiple: rk,
        };
    }
    let rk = render_multiple(k, iw, ih, min_render, max_long_edge);
    PreviewPlan {
        render_width: iw * rk,
        render_height: ih * rk,
        display_width: iw * k,
        display_height: ih * k,
        display_multiple: k,
        render_multiple: rk,
    }
}

/// Smallest whole multiple of `k_display` reaching the floor within the
/// texture budget (so the downsample is an exact integer factor).
fn render_multiple(k_display: u32, iw: u32, ih: u32, min_render: u32, max_long_edge: u32) -> u32 {
    let long = iw.max(ih);
    let mut factor = min_render.div_ceil(k_display).max(1);
    while factor > 1 && long * k_display * factor > max_long_edge {
        factor -= 1;
    }
    k_display * factor
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
                    assert_eq!(p.render_multiple % p.display_multiple, 0);
                    assert_eq!(p.render_width % p.display_width, 0);
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

    #[test]
    fn odd_multiples_step_back_and_tiny_windows_fit() {
        assert_eq!(plan((320, 320), (1600, 1600), true).display_multiple, 4);
        let p = plan((320, 320), (200, 200), true);
        assert_eq!(p.display_multiple, 0);
        assert!(p.display_width <= 200 && p.display_width > 0);
        assert!(p.render_multiple >= MIN_RENDER_MULTIPLE);
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
