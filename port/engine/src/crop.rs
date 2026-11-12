//! A crop of the source to an aspect ratio, before anything else sees it: a
//! port of the Mac's `SourceCrop` (same arithmetic, same tests). At scale 1
//! it keeps as much of the picture as the ratio allows, cutting one axis; a
//! larger scale zooms in, with room to move both ways. `x` and `y` place it:
//! 0 the left (top) edge, 1 the right (bottom).

use crate::Image;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Ratio {
    pub width: u32,
    pub height: u32,
}

impl Ratio {
    pub const fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }
    pub const SQUARE: Ratio = Ratio::new(1, 1);
    /// Square, then portrait shapes, then the same in landscape.
    pub const PORTRAIT: [Ratio; 4] = [Ratio::new(3, 4), Ratio::new(2, 3), Ratio::new(9, 16), Ratio::new(1, 2)];
    pub const LANDSCAPE: [Ratio; 4] = [Ratio::new(4, 3), Ratio::new(3, 2), Ratio::new(16, 9), Ratio::new(2, 1)];

    pub fn value(self) -> f64 {
        self.width as f64 / self.height as f64
    }
    /// "9:16".
    pub fn label(self) -> String {
        format!("{}:{}", self.width, self.height)
    }
    pub fn from_label(label: &str) -> Option<Ratio> {
        let (a, b) = label.split_once(':')?;
        let (w, h) = (a.trim().parse::<u32>().ok()?, b.trim().parse::<u32>().ok()?);
        (w > 0 && h > 0).then_some(Ratio::new(w, h))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cut {
    Width,
    Height,
    None,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Crop {
    pub ratio: Ratio,
    pub x: f64,
    pub y: f64,
    pub scale: f64,
}

impl Crop {
    /// Zooming in stops at an eighth of the largest crop's width.
    pub const MAX_SCALE: f64 = 8.0;

    pub fn new(ratio: Ratio) -> Self {
        Self { ratio, x: 0.5, y: 0.5, scale: 1.0 }
    }

    /// The largest crop, placed `position` along whichever axis it cuts.
    pub fn at(ratio: Ratio, position: f64) -> Self {
        Self { ratio, x: position, y: position, scale: 1.0 }
    }

    /// Which way the largest crop cuts a picture of this size (none within
    /// half a percent of the ratio).
    pub fn cut(&self, width: u32, height: u32) -> Cut {
        if width == 0 || height == 0 {
            return Cut::None;
        }
        let aspect = width as f64 / height as f64;
        if (aspect / self.ratio.value() - 1.0).abs() < 0.005 {
            Cut::None
        } else if aspect > self.ratio.value() {
            Cut::Width
        } else {
            Cut::Height
        }
    }

    pub fn largest(&self, width: u32, height: u32) -> (u32, u32) {
        match self.cut(width, height) {
            Cut::None => (width, height),
            Cut::Width => (even(height as f64 * self.ratio.value(), width), height),
            Cut::Height => (width, even(width as f64 / self.ratio.value(), height)),
        }
    }

    /// The crop in whole pixels: (x, y, width, height); sizes even where the
    /// picture allows, always inside the picture.
    pub fn rect(&self, width: u32, height: u32) -> (u32, u32, u32, u32) {
        let (bw, bh) = self.largest(width, height);
        let s = self.scale.clamp(1.0, Self::MAX_SCALE);
        let w = if s < 1.0001 { bw } else { even(bw as f64 / s, bw) };
        let h = if s < 1.0001 { bh } else { even(bh as f64 / s, bh) };
        let (px, py) = (self.x.clamp(0.0, 1.0), self.y.clamp(0.0, 1.0));
        (((width - w) as f64 * px).round() as u32, ((height - h) as f64 * py).round() as u32, w, h)
    }

    pub fn crops(&self, width: u32, height: u32) -> bool {
        let (_, _, w, h) = self.rect(width, height);
        w != width || h != height
    }

    /// The crop keeping the pixel rectangle (left, top, w): the inverse of
    /// `rect`, for dragging.
    pub fn placed(&self, left: f64, top: f64, w: f64, width: u32, height: u32) -> Crop {
        let (bw, _) = self.largest(width, height);
        let s = (bw as f64 / w.max(1.0)).clamp(1.0, Self::MAX_SCALE);
        let mut c = Crop { ratio: self.ratio, x: self.x, y: self.y, scale: s };
        let (_, _, rw, rh) = c.rect(width, height);
        let (room_x, room_y) = ((width - rw) as f64, (height - rh) as f64);
        if room_x > 0.0 {
            c.x = (left / room_x).clamp(0.0, 1.0);
        }
        if room_y > 0.0 {
            c.y = (top / room_y).clamp(0.0, 1.0);
        }
        c
    }

    /// The crop's part of `image` (the image itself when it cuts nothing).
    pub fn apply(&self, image: &Image) -> Image {
        let (x, y, w, h) = self.rect(image.width, image.height);
        if (w, h) == (image.width, image.height) {
            return image.clone();
        }
        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
        for row in y..y + h {
            let start = ((row * image.width + x) * 4) as usize;
            rgba.extend_from_slice(&image.rgba[start..start + (w * 4) as usize]);
        }
        Image::new(w, h, rgba)
    }
}

fn even(length: f64, limit: u32) -> u32 {
    let n = 2 * (length / 2.0).round() as i64;
    n.clamp(1, limit as i64) as u32
}

#[cfg(test)]
mod tests {
    //! The Mac's SourceCropTests (rect math), ported.
    use super::*;

    fn crop(r: Ratio) -> Crop {
        Crop::new(r)
    }

    #[test]
    fn keeps_all_it_can_and_cuts_one_axis() {
        assert_eq!(crop(Ratio::new(9, 16)).rect(1920, 1080), ((1920 - 608) / 2, 0, 608, 1080));
        assert_eq!(crop(Ratio::new(16, 9)).rect(1080, 1920), (0, (1920 - 608) / 2, 1080, 608));
        assert_eq!(crop(Ratio::SQUARE).rect(640, 480), (80, 0, 480, 480));
    }

    #[test]
    fn position_slides_along_the_cut_axis() {
        assert_eq!(Crop::at(Ratio::SQUARE, 0.0).rect(640, 480).0, 0);
        assert_eq!(Crop::at(Ratio::SQUARE, 1.0).rect(640, 480).0, 160);
        assert_eq!(Crop::at(Ratio::new(2, 1), 0.0).rect(640, 480), (0, 0, 640, 320));
        assert_eq!(Crop::at(Ratio::new(2, 1), 1.0).rect(640, 480).1, 160);
        assert_eq!(Crop::at(Ratio::SQUARE, 7.0).rect(640, 480).0, 160);
        assert_eq!(Crop::at(Ratio::SQUARE, -1.0).rect(640, 480).0, 0);
    }

    #[test]
    fn a_picture_already_that_shape_is_left_whole() {
        let c = crop(Ratio::new(16, 9));
        assert_eq!(c.cut(1920, 1080), Cut::None);
        assert_eq!(c.cut(1918, 1080), Cut::None);
        assert_eq!(c.rect(1918, 1080), (0, 0, 1918, 1080));
        assert_eq!(c.cut(1440, 1080), Cut::Height);
        assert_eq!(crop(Ratio::new(1, 2)).cut(1080, 1080), Cut::Width);
    }

    #[test]
    fn zooming_in_shrinks_and_frees_both_ways() {
        let middle = Crop { scale: 2.0, ..crop(Ratio::SQUARE) }.rect(640, 360);
        assert_eq!(middle, ((640 - 180) / 2, (360 - 180) / 2, 180, 180));
        let corner = Crop { x: 1.0, y: 1.0, scale: 2.0, ..crop(Ratio::SQUARE) }.rect(640, 360);
        assert_eq!((corner.0, corner.1), (460, 180));
        let own = crop(Ratio::new(16, 9));
        assert!(!own.crops(640, 360));
        let zoomed = Crop { scale: 1.25, ..own };
        assert!(zoomed.crops(640, 360));
        assert_eq!(zoomed.rect(640, 360).2, 512);
        assert_eq!(Crop { scale: 0.3, ..crop(Ratio::SQUARE) }.rect(640, 360).2, 360);
        assert_eq!(Crop { scale: 100.0, ..crop(Ratio::SQUARE) }.rect(640, 360).2, 46);
    }

    #[test]
    fn a_pixel_rectangle_maps_back() {
        let c = crop(Ratio::SQUARE);
        let p = c.placed(100.0, 60.0, 180.0, 640, 360);
        assert!((p.scale - 2.0).abs() < 1e-9);
        assert_eq!(p.rect(640, 360), (100, 60, 180, 180));
        let past = c.placed(600.0, -40.0, 180.0, 640, 360).rect(640, 360);
        assert_eq!((past.0, past.1), (460, 0));
        assert_eq!(c.placed(0.0, 0.0, 5000.0, 640, 360).scale, 1.0);
    }

    #[test]
    fn labels_round_trip_and_pixels_come_from_the_right_place() {
        for r in [Ratio::SQUARE].into_iter().chain(Ratio::PORTRAIT).chain(Ratio::LANDSCAPE) {
            assert_eq!(Ratio::from_label(&r.label()), Some(r));
        }
        assert_eq!(Ratio::from_label("nope"), None);
        assert_eq!(Ratio::from_label("0:4"), None);
        // A 4 × 2 picture whose pixels are their own x; a square crop at the right edge.
        let img = Image::new(4, 2, (0..8u8).flat_map(|i| [i % 4, 0, 0, 255]).collect());
        let out = Crop::at(Ratio::SQUARE, 1.0).apply(&img);
        assert_eq!((out.width, out.height), (2, 2));
        assert_eq!(out.rgba.chunks(4).map(|p| p[0]).collect::<Vec<_>>(), vec![2, 3, 2, 3]);
    }
}
