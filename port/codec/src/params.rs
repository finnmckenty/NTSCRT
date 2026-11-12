//! The stage's controls, settings and formats (`DigitalVideoParams.swift`).

use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};

use crate::codec::DigitalCodec;

/// The panel's groups, in the panel's order: the codec first, as the stage's
/// main choice.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DigitalGroup {
    Compression,
    Capture,
    Picture,
    Errors,
}

impl DigitalGroup {
    pub const ALL: [DigitalGroup; 4] = [
        DigitalGroup::Compression,
        DigitalGroup::Capture,
        DigitalGroup::Picture,
        DigitalGroup::Errors,
    ];

    /// The group's title in the panel.
    pub fn label(self) -> &'static str {
        match self {
            DigitalGroup::Compression => "Compression",
            DigitalGroup::Capture => "Capture",
            DigitalGroup::Picture => "Picture",
            DigitalGroup::Errors => "Errors",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum DigitalParamKind {
    Slider { min: f64, max: f64, percent: bool, unit: &'static str },
    /// A list of named choices, stored as the index.
    Choice(&'static [&'static str]),
}

/// One control of the Digital video stage. The stage is a small video codec
/// run for real — a camera's capture, 8×8 DCT blocks, real quantization
/// tables, motion-compensated prediction between keyframes, and a decoder
/// that can lose data — so, as with the Glitch stage, every control is a
/// setting the format or its transmission actually had. Blocking, smearing
/// and datamoshing come out of the codec; nothing is drawn.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DigitalParam {
    pub id: &'static str,
    pub label: &'static str,
    pub group: DigitalGroup,
    pub kind: DigitalParamKind,
    pub default_value: f64,
    pub help: &'static str,
    /// Whole steps only (frame rate), else `None`: continuous.
    pub step: Option<f64>,
}

const fn slider(min: f64, max: f64, percent: bool, unit: &'static str) -> DigitalParamKind {
    DigitalParamKind::Slider { min, max, percent, unit }
}

const fn pct(min: f64, max: f64) -> DigitalParamKind {
    slider(min, max, true, "")
}

/// The camera's picture controls (and its optics and sampling) default to
/// leaving the picture alone, so a double-click returns them there; the rest
/// default to the Webcam format's values.
static ALL_PARAMS: [DigitalParam; 20] = [
    DigitalParam {
        id: "frame_rate", label: "Frame rate", group: DigitalGroup::Capture,
        kind: slider(1.0, 60.0, false, "fps"), default_value: 15.0,
        help: "How many pictures a second the camera captures. Below the clip's own rate, frames repeat — the stutter of old webcams and video calls.",
        step: Some(1.0),
    },
    DigitalParam {
        id: "fields", label: "Fields", group: DigitalGroup::Capture,
        kind: DigitalParamKind::Choice(&["Progressive", "One field"]), default_value: 1.0,
        help: "Interlaced cameras like the VX1000 record each frame as two fields of alternate lines. One field keeps just one, as most DV reached the web: the CRT gets half as many lines, each twice as tall, and draws a scanline per line — the 240p look — while anywhere without the CRT each line shows twice, turning diagonals to stairs.",
        step: None,
    },
    DigitalParam {
        id: "aliasing", label: "Aliasing", group: DigitalGroup::Capture,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "The sensor reading detail it can't resolve, with nothing blurring it away first: fine stripes beat into moiré and edges into jaggies. Red, green and blue are sampled a third of a pixel apart, so where a beat drifts slowly its colors cycle through the rainbow. Above 50% the finest detail is boosted as it's read, for stronger moiré from sources not much sharper than the camera.",
        step: None,
    },
    DigitalParam {
        id: "sensor_noise", label: "Sensor noise", group: DigitalGroup::Capture,
        kind: pct(0.0, 1.0), default_value: 0.4,
        help: "Grain from a small, cheap image sensor, strongest in the color. It changes every frame, so the codec spends its bits on it and blocks crawl in flat areas.",
        step: None,
    },
    DigitalParam {
        id: "low_light_noise", label: "Low-light noise", group: DigitalGroup::Capture,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "How much the grain grows in dark scenes. As the light drops, the camera turns up its gain, and the sensor noise with it: up to eight times as strong at night, while daylight stays as set. Works on Sensor noise, so it needs some.",
        step: None,
    },
    DigitalParam {
        id: "noise_reduction", label: "Noise reduction", group: DigitalGroup::Capture,
        kind: pct(0.0, 1.0), default_value: 0.5,
        help: "The camera smoothing its own grain away before compressing. It flattens fine detail into a smeary, plastic look.",
        step: None,
    },
    DigitalParam {
        id: "ccd_response", label: "CCD response", group: DigitalGroup::Picture,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "The tone of a 90s 3-CCD camcorder like the VX1000, fitted to its footage. Auto exposure meters the middle of the frame and exposes bright; each color is compressed by the knee and then clips at white on its own, so warm skin and skies go yellow, then white; lens flare and the mishandled 7.5 IRE setup lift the blacks to a milky gray, more in bright scenes. 0% leaves the picture alone.",
        step: None,
    },
    DigitalParam {
        id: "white_balance", label: "White balance", group: DigitalGroup::Picture,
        kind: pct(-1.0, 1.0), default_value: 0.0,
        help: "Warm (positive) or cool (negative): the camera's guess at the light, often wrong.",
        step: None,
    },
    DigitalParam {
        id: "tint", label: "Tint", group: DigitalGroup::Picture,
        kind: pct(-1.0, 1.0), default_value: 0.0,
        help: "Magenta (positive) or green (negative), the other way a camera's color can drift.",
        step: None,
    },
    DigitalParam {
        id: "saturation", label: "Saturation", group: DigitalGroup::Picture,
        kind: pct(0.0, 2.0), default_value: 1.0,
        help: "Color strength. Consumer camcorders pushed it, reds and oranges most visibly.",
        step: None,
    },
    DigitalParam {
        id: "sharpening", label: "Sharpening", group: DigitalGroup::Picture,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "The camera's detail circuit: edges get bright and dark outlines (halos), the crisp, hard-edged video look.",
        step: None,
    },
    DigitalParam {
        id: "sharpening_width", label: "Halo width", group: DigitalGroup::Picture,
        kind: slider(1.0, 4.0, false, "px"), default_value: 1.0,
        help: "How far the sharpening halos reach, in camera pixels. 1 px is a 3-CCD camera's tight, crunchy edge; wider is the soft white rim around everything that cheap consumer camcorders drew. Works on Sharpening, so it needs some.",
        step: None,
    },
    DigitalParam {
        id: "codec", label: "Codec", group: DigitalGroup::Compression,
        kind: DigitalParamKind::Choice(&["DCT (MPEG, DV)", "Block colors (Video 1)"]), default_value: 0.0,
        help: "How the picture is compressed. DCT, the MPEG, H.263 and DV family, blurs detail inside 8×8 blocks and rings around edges. Block colors is Microsoft Video 1 (1992, Video for Windows): each 4×4 block becomes one, two or eight flat 15-bit colors and unchanged blocks are skipped — chunky two-tone edges and banded gradients, the early CD-ROM look.",
        step: None,
    },
    DigitalParam {
        id: "chroma", label: "Color", group: DigitalGroup::Compression,
        kind: DigitalParamKind::Choice(&["4:4:4 (full)", "4:2:2 (half)", "4:2:0 (quarter)", "4:1:1 (DV)"]),
        default_value: 2.0,
        help: "How much color detail is kept against brightness detail. Codecs store color at lower resolution because eyes notice it less: 4:2:2 halves it across, 4:2:0 across and down, and 4:1:1, NTSC DV's choice, quarters it across, smearing color sideways.",
        step: None,
    },
    DigitalParam {
        id: "quality", label: "Quality", group: DigitalGroup::Compression,
        kind: pct(0.0, 1.0), default_value: 0.749,
        help: "How finely each 8×8 block's detail is kept (the quantizer). Lower turns blocks into flat tiles and rings edges with mosquito noise.",
        step: None,
    },
    DigitalParam {
        id: "keyframe_interval", label: "Keyframe interval", group: DigitalGroup::Compression,
        kind: slider(0.0, 10.0, false, "s"), default_value: 0.0,
        help: "Seconds between keyframes (whole pictures). Between them the codec only sends what moved, so errors and datamoshing persist until the next one. 0 compresses every frame on its own, like Motion JPEG and DV.",
        step: None,
    },
    DigitalParam {
        id: "fixed_bitrate", label: "Fixed bitrate", group: DigitalGroup::Compression,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "How strictly the codec keeps to a fixed bitrate. Busy frames — motion, detail, grain — have to share the same bits, so they turn blocky, and the picture sharpens again when things settle.",
        step: None,
    },
    DigitalParam {
        id: "deblocking", label: "Deblocking", group: DigitalGroup::Compression,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "The decoder smoothing block edges, as H.264 does. Off keeps the hard tiles of older codecs; on trades them for smear.",
        step: None,
    },
    DigitalParam {
        id: "data_loss", label: "Data loss", group: DigitalGroup::Errors,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "Lost packets or tape dropouts. The decoder patches the gap from the last picture it had. Every frame on its own (DV), the patches flash and vanish; between keyframes, they smear and drift until the next keyframe.",
        step: None,
    },
    DigitalParam {
        id: "datamosh", label: "Datamosh", group: DigitalGroup::Errors,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "Keyframes thrown away. The changes that follow are applied to the old picture instead of the new one: motion drags the previous scene's pixels around until a keyframe gets through. Needs a keyframe interval above 0.",
        step: None,
    },
];

/// The settings the stage starts with in a new window (it starts switched
/// off): Finn's "Cheap camcorder" look — a 2000s consumer MiniDV camera,
/// grain that grows in the dark. Kept apart from each control's
/// `default_value`, which formats, double-click resets and looks saved before
/// a control existed rely on.
const STARTING_VALUES: [(&str, f64); 20] = [
    ("frame_rate", 30.0),
    ("fields", 1.0),
    ("aliasing", 0.380103),
    ("sensor_noise", 0.4),
    ("low_light_noise", 0.640871),
    ("noise_reduction", 0.0),
    ("ccd_response", 0.679635),
    ("white_balance", 0.0),
    ("tint", 0.0),
    ("saturation", 1.0),
    ("sharpening", 0.0),
    ("sharpening_width", 4.0),
    ("codec", 0.0),
    ("chroma", 2.0),
    ("quality", 0.749),
    ("keyframe_interval", 0.0),
    ("fixed_bitrate", 0.0),
    ("deblocking", 0.0),
    ("data_loss", 0.0),
    ("datamosh", 0.0),
];

/// Controls that set the stream's structure — when frames are captured,
/// where keyframes fall, the color layout, and how the sensor samples through
/// the lens. They hold for a whole render (keyframes on the timeline don't
/// animate them).
pub const STRUCTURE_IDS: [&str; 6] = ["frame_rate", "keyframe_interval", "chroma", "fields", "aliasing", "codec"];

impl DigitalParam {
    /// Every control, in the Mac's order.
    pub fn all() -> &'static [DigitalParam] {
        &ALL_PARAMS
    }

    pub fn by_id(id: &str) -> Option<&'static DigitalParam> {
        ALL_PARAMS.iter().find(|p| p.id == id)
    }

    pub fn is_choice(&self) -> bool {
        matches!(self.kind, DigitalParamKind::Choice(_))
    }

    /// Every control's `default_value`.
    pub fn default_values() -> BTreeMap<String, f64> {
        ALL_PARAMS.iter().map(|p| (p.id.to_string(), p.default_value)).collect()
    }

    /// See `STARTING_VALUES`: the defaults with the starting look on top.
    pub fn starting_values() -> BTreeMap<String, f64> {
        let mut v = Self::default_values();
        for (id, x) in STARTING_VALUES {
            v.insert(id.to_string(), x);
        }
        v
    }

    /// Controls that do nothing with a codec, so the panel hides them: Video
    /// 1 keeps full-resolution color, has no deblocking, and no motion for a
    /// datamosh to drag.
    pub fn unused_by(codec: DigitalCodecKind) -> &'static [&'static str] {
        match codec {
            DigitalCodecKind::Dct => &[],
            DigitalCodecKind::BlockColors => &["chroma", "deblocking", "datamosh"],
        }
    }

    pub fn applies(&self, codec: DigitalCodecKind) -> bool {
        !Self::unused_by(codec).contains(&self.id)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DigitalCodecKind {
    /// The MPEG / H.263 / DV family (`DigitalCodec`).
    Dct = 0,
    /// Microsoft Video 1 (`video1`).
    BlockColors = 1,
}

impl DigitalCodecKind {
    pub const ALL: [DigitalCodecKind; 2] = [DigitalCodecKind::Dct, DigitalCodecKind::BlockColors];

    pub fn from_raw(raw: i64) -> Option<Self> {
        match raw {
            0 => Some(DigitalCodecKind::Dct),
            1 => Some(DigitalCodecKind::BlockColors),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChromaSubsampling {
    Full = 0,
    HalfWide = 1,
    HalfBoth = 2,
    QuarterWide = 3,
}

impl ChromaSubsampling {
    pub const ALL: [ChromaSubsampling; 4] = [
        ChromaSubsampling::Full,
        ChromaSubsampling::HalfWide,
        ChromaSubsampling::HalfBoth,
        ChromaSubsampling::QuarterWide,
    ];

    pub fn from_raw(raw: i64) -> Option<Self> {
        Self::ALL.get(usize::try_from(raw).ok()?).copied()
    }

    /// Chroma plane step (luma pixels per chroma sample) across and down.
    pub fn factors(self) -> (usize, usize) {
        match self {
            ChromaSubsampling::Full => (1, 1),
            ChromaSubsampling::HalfWide => (2, 1),
            ChromaSubsampling::HalfBoth => (2, 2),
            ChromaSubsampling::QuarterWide => (4, 1),
        }
    }
}

/// Swift's `Int(x.rounded())`: to the nearest, halves away from zero.
fn round_to_int(x: f64) -> i64 {
    x.round() as i64
}

/// The Digital video stage's settings for one moment, keyed by
/// `DigitalParam::id` (the same flat form looks and keyframes store).
///
/// Equality and hashing compare values as numbers, as the Mac's
/// `[String: Double]` does (so 0 and -0 are the same setting).
#[derive(Clone, Debug)]
pub struct DigitalSettings {
    pub values: BTreeMap<String, f64>,
}

impl PartialEq for DigitalSettings {
    fn eq(&self, other: &Self) -> bool {
        self.values.len() == other.values.len()
            && self.values.iter().zip(other.values.iter()).all(|((ka, va), (kb, vb))| ka == kb && va == vb)
    }
}

impl Eq for DigitalSettings {}

impl Hash for DigitalSettings {
    fn hash<H: Hasher>(&self, state: &mut H) {
        for (k, v) in &self.values {
            k.hash(state);
            hash_f64(*v, state);
        }
    }
}

/// Hash a double the way `==` sees it (0 and -0 alike).
pub(crate) fn hash_f64<H: Hasher>(v: f64, state: &mut H) {
    let v = if v == 0.0 { 0.0 } else { v };
    v.to_bits().hash(state);
}

impl Default for DigitalSettings {
    fn default() -> Self {
        DigitalSettings { values: DigitalParam::default_values() }
    }
}

impl DigitalSettings {
    /// `values` over every control's default.
    pub fn new<K: Into<String>, I: IntoIterator<Item = (K, f64)>>(values: I) -> Self {
        let mut v = DigitalParam::default_values();
        for (k, x) in values {
            v.insert(k.into(), x);
        }
        DigitalSettings { values: v }
    }

    /// A control's value: what's set, else its default, else 0.
    pub fn get(&self, id: &str) -> f64 {
        self.values
            .get(id)
            .copied()
            .or_else(|| DigitalParam::by_id(id).map(|p| p.default_value))
            .unwrap_or(0.0)
    }

    pub fn set(&mut self, id: &str, value: f64) {
        self.values.insert(id.to_string(), value);
    }

    pub fn codec(&self) -> DigitalCodecKind {
        DigitalCodecKind::from_raw(round_to_int(self.get("codec"))).unwrap_or(DigitalCodecKind::Dct)
    }

    /// The color layout the codec codes: Video 1 always keeps full color.
    pub fn chroma(&self) -> ChromaSubsampling {
        if self.codec() == DigitalCodecKind::BlockColors {
            return ChromaSubsampling::Full;
        }
        ChromaSubsampling::from_raw(round_to_int(self.get("chroma"))).unwrap_or(ChromaSubsampling::HalfBoth)
    }

    /// A control's value as the codec uses it: 0 for controls it doesn't have
    /// (deblocking and datamosh under Video 1).
    pub fn effective(&self, id: &str) -> f64 {
        if DigitalParam::unused_by(self.codec()).contains(&id) && id != "chroma" {
            0.0
        } else {
            self.get(id)
        }
    }

    /// Values saved before 0.19 (look version 1), mapped onto today's
    /// controls: Exposure and Black level became CCD response (the stronger
    /// of the two decides), Lens softness is gone, and Quality moved to an
    /// even curve — converted to the value giving the same quantizer.
    pub fn migrated(values: &BTreeMap<String, f64>, look_version: i64) -> BTreeMap<String, f64> {
        let mut v = values.clone();
        if look_version < 2 {
            if let Some(q) = v.get("quality").copied() {
                v.insert("quality".into(), DigitalCodec::quality_from_jpeg_scale(q));
            }
        }
        let exposure = v.remove("exposure");
        let black = v.remove("black_level");
        v.remove("lens_blur");
        if !v.contains_key("ccd_response") && (exposure.is_some() || black.is_some()) {
            let m = swift_max(swift_max(0.0, exposure.unwrap_or(0.0) / 0.6), black.unwrap_or(0.0) / 0.08);
            v.insert("ccd_response".into(), swift_min(1.0, m));
        }
        v
    }

    /// The same settings with the structure controls taken from `base`.
    pub fn holding_structure(&self, base: &DigitalSettings) -> DigitalSettings {
        let mut v = self.values.clone();
        for id in STRUCTURE_IDS {
            v.insert(id.to_string(), base.get(id));
        }
        DigitalSettings::new(v)
    }
}

/// Swift's `min`/`max` (the second argument wins ties; no NaN special case).
#[inline(always)]
pub(crate) fn swift_min<T: PartialOrd>(x: T, y: T) -> T {
    if y < x { y } else { x }
}
#[inline(always)]
pub(crate) fn swift_max<T: PartialOrd>(x: T, y: T) -> T {
    if y >= x { y } else { x }
}

/// A named starting point: the stage's settings plus the capture width, which
/// becomes the Downscale width.
#[derive(Clone, Copy, Debug)]
pub struct DigitalFormat {
    pub id: &'static str,
    pub name: &'static str,
    pub width: usize,
    /// The format's values (controls it doesn't list keep their defaults).
    pub values: &'static [(&'static str, f64)],
    pub blurb: &'static str,
}

static ALL_FORMATS: [DigitalFormat; 6] = [
    DigitalFormat {
        id: "webcam", name: "Webcam (2005)", width: 320,
        values: &[("frame_rate", 15.0), ("aliasing", 0.15),
                  ("sensor_noise", 0.4), ("noise_reduction", 0.5),
                  ("ccd_response", 0.5), ("white_balance", -0.15), ("saturation", 0.85),
                  ("sharpening", 0.25), ("chroma", 2.0),
                  ("quality", 0.749), ("keyframe_interval", 0.0), ("fixed_bitrate", 0.0),
                  ("deblocking", 0.0), ("data_loss", 0.0), ("datamosh", 0.0)],
        blurb: "320 × 240, 15 fps, a noisy sensor, each frame compressed on its own.",
    },
    DigitalFormat {
        id: "video_call", name: "Video call", width: 320,
        values: &[("frame_rate", 15.0), ("sensor_noise", 0.25), ("noise_reduction", 0.6),
                  ("ccd_response", 0.3), ("saturation", 0.9), ("chroma", 2.0),
                  ("quality", 0.749), ("keyframe_interval", 4.0), ("fixed_bitrate", 0.8),
                  ("deblocking", 0.6), ("data_loss", 0.15), ("datamosh", 0.0)],
        blurb: "A squeezed bitrate and lost packets that smear until the next keyframe.",
    },
    DigitalFormat {
        id: "minidv", name: "MiniDV", width: 720,
        values: &[("frame_rate", 30.0), ("fields", 1.0), ("aliasing", 0.6),
                  ("sensor_noise", 0.12), ("noise_reduction", 0.0),
                  ("ccd_response", 1.0), ("white_balance", 0.4), ("tint", 0.2), ("saturation", 1.15),
                  ("sharpening", 0.6), ("chroma", 3.0),
                  ("quality", 0.894), ("keyframe_interval", 0.0), ("fixed_bitrate", 0.3),
                  ("deblocking", 0.0), ("data_loss", 0.0), ("datamosh", 0.0)],
        blurb: "The VX1000 skate-video look: one field line-doubled, hard sharpening, aliasing and color moiré, blown highlights, warm saturated color, gray blacks, color at a quarter width (4:1:1).",
    },
    DigitalFormat {
        id: "early_web", name: "Early web video", width: 320,
        values: &[("frame_rate", 15.0), ("sensor_noise", 0.0), ("noise_reduction", 0.0), ("chroma", 2.0),
                  ("quality", 0.651), ("keyframe_interval", 5.0), ("fixed_bitrate", 0.7),
                  ("deblocking", 0.0), ("data_loss", 0.0), ("datamosh", 0.0)],
        blurb: "240p streaming: few bits, coarse blocks, and keyframes that pump.",
    },
    DigitalFormat {
        id: "cd_rom", name: "CD-ROM (Video 1)", width: 240,
        values: &[("codec", 1.0), ("frame_rate", 12.0), ("sensor_noise", 0.0), ("noise_reduction", 0.0),
                  ("quality", 0.57), ("keyframe_interval", 1.25), ("fixed_bitrate", 0.0),
                  ("data_loss", 0.0)],
        blurb: "Video for Windows off a 90s CD-ROM: 240 wide, 12 fps, Microsoft Video 1's flat two-tone blocks and banded 15-bit color, a keyframe every 15 frames.",
    },
    DigitalFormat {
        id: "datamosh", name: "Datamosh", width: 480,
        values: &[("frame_rate", 30.0), ("sensor_noise", 0.0), ("noise_reduction", 0.0), ("chroma", 2.0),
                  ("quality", 0.826), ("keyframe_interval", 1.0), ("fixed_bitrate", 0.3),
                  ("deblocking", 0.0), ("data_loss", 0.0), ("datamosh", 1.0)],
        blurb: "Keyframes removed: motion drags the old picture around.",
    },
];

impl DigitalFormat {
    /// Every format, in the Mac's order.
    pub fn all() -> &'static [DigitalFormat] {
        &ALL_FORMATS
    }

    pub fn by_id(id: &str) -> Option<&'static DigitalFormat> {
        ALL_FORMATS.iter().find(|f| f.id == id)
    }

    /// The format's values as a map (only what it lists).
    pub fn values_map(&self) -> BTreeMap<String, f64> {
        self.values.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    /// The format's full settings.
    pub fn settings(&self) -> DigitalSettings {
        DigitalSettings::new(self.values.iter().map(|(k, v)| (*k, *v)))
    }

    /// The format these values (and width) match exactly, if any.
    pub fn matching(values: &BTreeMap<String, f64>, width: usize) -> Option<&'static DigitalFormat> {
        let s = DigitalSettings::new(values.iter().map(|(k, v)| (k.clone(), *v)));
        ALL_FORMATS.iter().find(|f| {
            let fs = f.settings();
            f.width == width && ALL_PARAMS.iter().all(|p| (s.get(p.id) - fs.get(p.id)).abs() < 1e-9)
        })
    }
}
