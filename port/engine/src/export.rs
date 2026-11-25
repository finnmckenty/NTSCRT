//! Export sizes: ports of the Mac's `ScanlineGrid`, `SupersampledPass`,
//! `AppState.exportVideoSize` / `exportGifSize` / `exportBitrate`.
//!
//! CRT shaders draw scanlines and masks in output pixels, so the size they
//! render at is part of the look. Every export renders the shader at the
//! size the preview does (`preview::render_multiple`: a whole even multiple
//! of the picture going in, the same at any output size) and integrates
//! that down — or, for an output larger than the render, up — to the size
//! asked for, as the preview does to fit its window. So an export looks
//! like the preview, and a line never lands on a fractional number of
//! rendered rows. A size that is itself a whole multiple of the picture
//! (`snapped_size`) scales every line and column alike.

/// The size the shader renders at for `chain_input` (width, scan lines):
/// the preview's multiple of the picture. The picture's shape is the
/// target's: with one field each line stands for two picture rows, and the
/// render has whole lines either way. Mac: SupersampledPass.renderSize.
pub fn render_size(chain_input: (u32, u32), target: (u32, u32)) -> (u32, u32) {
    if chain_input.0 == 0 || chain_input.1 == 0 || target.0 == 0 || target.1 == 0 {
        return target;
    }
    let picture_height = chain_input.0 as f64 * target.1 as f64 / target.0 as f64;
    let line_height = ((picture_height / chain_input.1 as f64).round() as u32).max(1);
    // (The shader's picture: this one, or a smaller one when it is too
    // large to render; the engine makes it.)
    let lines = crate::preview::shader_input(chain_input);
    let m = crate::preview::render_multiple((lines.0, lines.1 * line_height));
    (lines.0 * m, lines.1 * line_height * m)
}

/// The nearest size whose height is a whole multiple of the input height
/// (even multiples from 2 up; 1× kept). `line_height` > 1 for one field.
pub fn snapped_size(input: (u32, u32), target_height: u32, line_height: u32) -> (u32, u32) {
    let (iw, ih) = input;
    if iw == 0 || ih == 0 || target_height == 0 {
        return input;
    }
    let exact = target_height as f64 / ih as f64;
    let mut k = (exact.round() as u32).max(1);
    if k >= 2 && k % 2 != 0 {
        let below = (k - 1) as f64;
        let above = (k + 1) as f64;
        k = if exact - below < above - exact { k - 1 } else { k + 1 };
    }
    let k = k.max(1);
    (iw * k / line_height.max(1), ih * k)
}

/// The video (and PNG) export size: the long edge, the other side following
/// the picture's shape, both even; snapped onto the grid when asked.
/// `snap` is the chain input (width, lines) and its line height.
pub fn video_size(long_edge: u32, aspect: f64, snap: Option<((u32, u32), u32)>) -> (u32, u32) {
    let (w, h) = if aspect >= 1.0 {
        (long_edge, ((long_edge as f64 / aspect).round() as u32).max(64))
    } else {
        (((long_edge as f64 * aspect).round() as u32).max(64), long_edge)
    };
    snap_even((w & !1, h & !1), snap)
}

/// The GIF size: its own width, the height following the picture's shape.
pub fn gif_size(width: u32, aspect: f64, snap: Option<((u32, u32), u32)>) -> (u32, u32) {
    let w = width.max(64);
    let h = ((w as f64 / aspect).round() as u32).max(64);
    snap_even((w & !1, h & !1), snap)
}

fn snap_even(size: (u32, u32), snap: Option<((u32, u32), u32)>) -> (u32, u32) {
    match snap {
        Some((input, line_height)) if input.0 > 0 && input.1 > 0 => {
            let (w, h) = snapped_size(input, size.1, line_height);
            (w & !1, h & !1)
        }
        _ => size,
    }
}

/// Bits per pixel per frame for each export quality (Standard … Maximum).
pub const QUALITIES: [(&str, f64); 4] = [("Standard", 0.12), ("High", 0.25), ("Very high", 0.5), ("Maximum", 1.0)];

/// The Mac's bitrate: pixels × fps × bits per pixel, at least 2 Mb/s.
pub fn bitrate(size: (u32, u32), fps: f64, bits_per_pixel: f64) -> u32 {
    ((size.0 as f64 * size.1 as f64 * fps * bits_per_pixel) as u32).max(2_000_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_at_the_previews_size_whatever_the_file() {
        assert_eq!(render_size((320, 240), (1920, 1440)), (1920, 1440));
        assert_eq!(render_size((320, 240), (480, 360)), (1920, 1440));
        assert_eq!(render_size((640, 480), (1920, 1440)), (3840, 2880));
        assert_eq!(render_size((256, 192), (1920, 1440)), (2048, 1536));
        // One field: 300 lines, each two picture rows; whole lines.
        assert_eq!(render_size((480, 300), (640, 800)), (2880, 3600));
        // Too large to render at two rows a line: the shader gets it smaller.
        assert_eq!(render_size((1904, 2544), (1436, 1920)), (3066, 4096));
    }

    #[test]
    fn snaps_to_even_multiples() {
        assert_eq!(snapped_size((320, 240), 1080, 1), (1280, 960), "4.5 → 4");
        assert_eq!(snapped_size((320, 240), 700, 1), (640, 480), "2.9 → 3 is odd → 2 is nearer than 4");
        assert_eq!(snapped_size((320, 240), 250, 1), (320, 240), "1× is kept");
        assert_eq!(snapped_size((320, 120), 480, 2), (640, 480), "one field: width follows the picture");
    }

    #[test]
    fn export_sizes_follow_the_mac() {
        assert_eq!(video_size(1920, 4.0 / 3.0, None), (1920, 1440));
        assert_eq!(video_size(1920, 9.0 / 16.0, None), (1080, 1920));
        assert_eq!(video_size(1920, 4.0 / 3.0, Some(((320, 240), 1))), (1920, 1440), "6× is already on the grid");
        // One field: 120 lines, each two rows; the width follows the picture.
        assert_eq!(video_size(1920, 4.0 / 3.0, Some(((320, 120), 2))), (1920, 1440));
        assert_eq!(video_size(174, 4.0 / 3.0, Some(((320, 121), 1))), (320, 120), "1× of an odd input, made even");
        assert_eq!(gif_size(480, 16.0 / 9.0, None), (480, 270 & !1));
        assert_eq!(bitrate((1920, 1440), 30.0, 0.25), 20_736_000);
        assert_eq!(bitrate((320, 240), 12.0, 0.12), 2_000_000);
    }
}
