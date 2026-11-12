//! Export sizes and the scanline guard: ports of the Mac's `ScanlineGrid`,
//! `AppState.exportVideoSize` / `exportGifSize` / `exportBitrate`.
//!
//! CRT shaders draw scanlines in output pixels. When the output height isn't
//! a whole multiple of the chain input's, lines land on alternately one and
//! two rows and the pattern bands. Two ways out, as on the Mac: render at a
//! whole multiple and integrate down (`supersample_factor`), or snap the size
//! onto the grid (`snapped_size`).

/// Multiple of the chain input to render at before box-filtering down to
/// `target_height`; 1 = render straight to the target.
pub fn supersample_factor(input_height: u32, target_height: u32) -> u32 {
    if input_height == 0 || target_height == 0 || target_height % input_height == 0 {
        return 1;
    }
    // At 3+ rows per line the scanlines are already resolved.
    if target_height as f64 / input_height as f64 >= 3.0 {
        return 1;
    }
    // 4 rows per line, even, stepped down when it would be disproportionate.
    let mut k = 4;
    while k > 2 && (k * input_height > 4 * target_height || k * input_height > 4096) {
        k -= 2;
    }
    if k * input_height > 4 * target_height || k * input_height > 4096 {
        return 1;
    }
    k
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
    fn supersamples_only_below_three_rows_a_line() {
        assert_eq!(supersample_factor(240, 960), 1, "an exact multiple is left alone");
        assert_eq!(supersample_factor(240, 1080), 1, "4.5 rows a line resolves already");
        assert_eq!(supersample_factor(416, 702), 4, "1.69 rows a line: render 4 per line");
        // 4K with no downscale into a 540-row GIF is already minifying.
        assert_eq!(supersample_factor(2160, 540), 1);
        // Too big for the texture budget at 4 and 2.
        assert_eq!(supersample_factor(1200, 2000), 2, "4× would pass 4096 rows; 2× fits");
        assert_eq!(supersample_factor(2100, 2200), 1, "even 2× passes 4096 rows");
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
