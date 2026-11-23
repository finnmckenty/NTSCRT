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
static ALL_PARAMS: [DigitalParam; 32] = [
    DigitalParam {
        id: "frame_rate", label: "Frame rate", group: DigitalGroup::Capture,
        kind: slider(1.0, 60.0, false, "fps"), default_value: 15.0,
        help: "How many pictures a second the camera captures. Below the clip's own rate, frames repeat — the stutter of old webcams and video calls.",
        step: Some(1.0),
    },
    DigitalParam {
        id: "fields", label: "Fields", group: DigitalGroup::Capture,
        kind: DigitalParamKind::Choice(&["Progressive", "One field", "Woven fields", "Blended fields"]), default_value: 1.0,
        help: "Interlaced cameras like the VX1000 record each frame as two fields of alternate lines, taken a moment apart. One field keeps just one, as most DV reached the web: the CRT gets half as many lines, each twice as tall, and draws a scanline per line — the 240p look — while anywhere without the CRT each line shows twice, turning diagonals to stairs. Woven fields shows the two together: anything that moved between them breaks into comb teeth, which the codec then struggles with. Blended fields mixes them instead, the cheap deinterlacing of DV on the web: moving things get a ghosted double edge and the picture softens a little. Both need a clip with motion; the earlier field comes from the frame before.",
        step: None,
    },
    DigitalParam {
        id: "sensor", label: "Sensor", group: DigitalGroup::Capture,
        kind: DigitalParamKind::Choice(&["Three chips", "One chip (webcam)", "One chip (camcorder)"]), default_value: 0.0,
        help: "Three chips (3-CCD, the VX1000) read red, green and blue everywhere. One chip (webcam) has a mosaic of red, green and blue filters over a single sensor, each pixel seeing one color and guessing the other two from its neighbors, as webcams and digital cameras do: fine detail and sharp edges pick up false colors and a zipper pattern. One chip (camcorder) is how 90s consumer camcorders worked: cyan, yellow, magenta and green filters read two rows at a time, with color carried as two signals on alternate lines, so every line borrows half its color from the line above. Color has half the detail and lags a line, smearing down and fringing at horizontal edges; sharp vertical edges pick up false color; brightness is a little soft. With either one chip, Sensor noise goes through the same reconstruction, so its color grain comes out in blotches rather than fine specks. Aliasing makes the false color stronger.",
        step: None,
    },
    DigitalParam {
        id: "smear", label: "Vertical smear", group: DigitalGroup::Capture,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "A CCD's vertical smear: light from a very bright spot leaks into its whole column as the picture is read out, drawing a pale streak up and down through lamps, headlights and the sun. Strongest in dark scenes, where the camera has opened up.",
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
        help: "The tone of a 90s DV camcorder: four things this one slider turns up together. Auto exposure meters the middle of the frame and exposes bright, as far as the gain the camera has left, so a dark scene stays dark instead of being pushed up to gray. Highlights: each color is compressed by the knee and then clips at white on its own, so warm skin and skies go yellow, then white; what is already white in the source clips too. Lens flare lays a veil over the shadows, more in bright scenes. And DV's levels are shown as stored: black sits at 16 of 255, a milky gray, and color comes out a few percent weak. The amounts are fitted to VX1000 footage. 0% leaves the picture alone.",
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
        id: "block_size", label: "Block size", group: DigitalGroup::Compression,
        kind: DigitalParamKind::Choice(&["4 px", "8 px", "16 px"]), default_value: 1.0,
        help: "The size of the blocks the picture is compressed in, whatever its resolution. 8 px is what MPEG, JPEG and DV use. 16 px makes the tiles, the ringing around edges and everything else the codec does twice as big, for blocks that still show in a large picture; 4 px makes them half the size, a finer grit for a small one. Motion, lost data and datamoshing work in squares twice the block's size, so they grow and shrink with it.",
        step: None,
    },
    DigitalParam {
        id: "chroma", label: "Color", group: DigitalGroup::Compression,
        kind: DigitalParamKind::Choice(&["4:4:4 (full)", "4:2:2 (half)", "4:2:0 (quarter)", "4:1:1 (DV)"]), default_value: 2.0,
        help: "How much color detail is kept against brightness detail. Codecs store color at lower resolution because eyes notice it less: 4:2:2 halves it across, 4:2:0 across and down, and 4:1:1, NTSC DV's choice, quarters it across, smearing color sideways.",
        step: None,
    },
    DigitalParam {
        id: "chroma_upsampling", label: "Color decode", group: DigitalGroup::Compression,
        kind: DigitalParamKind::Choice(&["Smooth", "Blocky"]), default_value: 0.0,
        help: "How the decoder scales the stored color back up to the picture. Smooth interpolates. Blocky repeats each color sample, as early DV decoders did: colored edges, reds most of all, turn into steps two or four pixels wide. Needs Color below 4:4:4.",
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
        id: "bitrate_limit", label: "Bitrate limit", group: DigitalGroup::Compression,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "A real budget of bits, counted from what the codec actually sends. 0% is no limit; from there it tightens from about 2 bits for each pixel of a frame down to a hundredth of one (the panel shows it in kbps for the current size and frame rate). A frame that needs more than its share is compressed harder until it fits, as far as about Quality 46%. Every frame on its own, each frame gets the same bits, as on DV tape, and that floor is reached around the middle of the slider. With a keyframe interval, bits can be borrowed from the Buffer: once it's used up, a cut or a keyframe has to fit in one frame's share, lands as coarse blocks, and sharpens over the frames that follow; tighter still, the codec skips frames and the picture freezes for a moment. It starts to bite sooner at a high Quality.",
        step: None,
    },
    DigitalParam {
        id: "rate_buffer", label: "Buffer", group: DigitalGroup::Compression,
        kind: slider(0.0, 5.0, false, "s"), default_value: 1.0,
        help: "How far ahead of the Bitrate limit the codec may run: this many seconds' worth of bits to borrow for a keyframe, a cut or a burst of motion, paid back by the frames after it. Small, every keyframe and cut collapses into blocks and recovers; large, they pass cleanly and the picture sags later instead, when the buffer runs out. Each keyframe starts a fresh buffer. Works on Bitrate limit, and needs a keyframe interval above 0.",
        step: None,
    },
    DigitalParam {
        id: "deblocking", label: "Deblocking", group: DigitalGroup::Compression,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "The decoder smoothing block edges, as H.264 does. Off keeps the hard tiles of older codecs; on trades them for smear.",
        step: None,
    },
    DigitalParam {
        id: "generations", label: "Generations", group: DigitalGroup::Compression,
        kind: slider(0.0, 20.0, false, ""), default_value: 0.0,
        help: "How many more times the picture has been decoded and compressed again at the same Quality: a video saved and re-uploaded over and over. Each time its blocks land a few pixels from where the last ones were, so block edges turn into ringing, the ringing into mush, and color bleeds and drifts — the deep-fried look. 0 is the first compression alone.",
        step: Some(1.0),
    },
    DigitalParam {
        id: "data_loss", label: "Data loss", group: DigitalGroup::Errors,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "Lost packets or tape dropouts. The decoder patches the gap from the last picture it had. Every frame on its own (DV), the patches flash and vanish; between keyframes, they smear and drift until the next keyframe.",
        step: None,
    },
    DigitalParam {
        id: "loss_pattern", label: "Loss pattern", group: DigitalGroup::Errors,
        kind: DigitalParamKind::Choice(&["Packets", "DV tape", "Clogged head"]), default_value: 0.0,
        help: "Where Data loss falls. Packets: runs of blocks in reading order, as a stream loses them. DV tape: DV scatters each track's blocks over five rectangles of the picture, so a dropout shows as small stale blocks repeated in a regular pattern, a scratch holds its pattern for a while, and a lost track freezes five whole rectangles. Clogged head: one of the two heads reads badly, so every other band of the picture (a tenth of its height each) breaks up and freezes. The two tape patterns hold the last good picture until new data arrives; about once a second the tape reads clean and everything catches up.",
        step: None,
    },
    DigitalParam {
        id: "concealment", label: "Lost blocks show", group: DigitalGroup::Errors,
        kind: DigitalParamKind::Choice(&["Last picture", "Gray", "Green", "Stretched"]), default_value: 0.0,
        help: "What the decoder puts where data was lost. Last picture is the usual patch. Gray and Green are decoders that leave the gap empty: flat gray, or the green of an all-zero picture. Stretched fills the gap by pulling the row above it downward. Between keyframes, whatever is put there is then dragged around by the motion that follows. Works on Data loss, so it needs some.",
        step: None,
    },
    DigitalParam {
        id: "bit_errors", label: "Bit errors", group: DigitalGroup::Errors,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "Damaged data that still arrives, and is decoded wrong. A block's detail turns into a bright striped or checkered pattern; a brightness or color error carries on along the row as a band, sometimes down the rest of the picture; the rest of a row lands a block or two out of place. Every frame on its own, the damage flashes; between keyframes it stays, and moves with the picture, until the next keyframe.",
        step: None,
    },
    DigitalParam {
        id: "datamosh", label: "Datamosh", group: DigitalGroup::Errors,
        kind: pct(0.0, 1.0), default_value: 0.0,
        help: "Keyframes thrown away. The changes that follow are applied to the old picture instead of the new one: motion drags the previous scene's pixels around until a keyframe gets through. Needs a keyframe interval above 0.",
        step: None,
    },
    DigitalParam {
        id: "mosh_motion", label: "Added motion", group: DigitalGroup::Errors,
        kind: DigitalParamKind::Choice(&["None", "Pan", "Tilt", "Zoom", "Swirl"]), default_value: 0.0,
        help: "Motion the decoder is told about that never happened, like a camera move's frames repeated over and over (a datamosher's \"bloom\"): the picture is pushed along it a block at a time with nothing to correct it, melting until the next keyframe puts it right. It gives a still picture something to mosh with; on a clip it adds to the clip's own motion. Needs a keyframe interval above 0; turn up Datamosh to keep the keyframes from repairing it.",
        step: None,
    },
    DigitalParam {
        id: "mosh_speed", label: "Motion speed", group: DigitalGroup::Errors,
        kind: pct(-1.0, 1.0), default_value: 0.5,
        help: "How fast the added motion pushes the picture, and which way: right or left, down or up, in or out, clockwise or counterclockwise. At 100% the picture's edge moves a fortieth of its width every frame.",
        step: None,
    },
];

/// The settings the stage starts with in a new window (it starts switched
/// off), and what a user gets the first time they switch it on: Finn's
/// "MiniDV tape" look (2026-11-22) — a one-chip camcorder at 24 frames a
/// second, DV's quarter-width color decoded blocky, strong aliasing, a little
/// sharpening and grain — because MiniDV is what most people switching this
/// on are looking for. Kept apart from each control's `default_value`, which
/// formats, double-click resets and looks saved before a control existed
/// rely on. Only this stage's values: the Downscale and the other stages
/// stay as they are.
const STARTING_VALUES: [(&str, f64); 32] = [
    ("frame_rate", 24.0),
    ("fields", 1.0),
    ("sensor", 2.0),
    ("smear", 0.0),
    ("aliasing", 0.8209776182432433),
    ("sensor_noise", 0.37214335851899205),
    ("low_light_noise", 0.135962134009009),
    ("noise_reduction", 0.0),
    ("ccd_response", 0.16154631193693694),
    ("white_balance", 0.0),
    ("tint", 0.0),
    ("saturation", 1.0),
    ("sharpening", 0.2507859421921922),
    ("sharpening_width", 1.2710830023435595),
    ("codec", 0.0),
    ("block_size", 1.0),
    ("chroma", 3.0),
    ("chroma_upsampling", 1.0),
    ("quality", 0.749),
    ("keyframe_interval", 0.0),
    ("fixed_bitrate", 0.0),
    ("bitrate_limit", 0.0),
    ("rate_buffer", 1.0),
    ("deblocking", 0.0),
    ("generations", 0.0),
    ("data_loss", 0.0),
    ("loss_pattern", 0.0),
    ("concealment", 0.0),
    ("bit_errors", 0.0),
    ("datamosh", 0.0),
    ("mosh_motion", 0.0),
    ("mosh_speed", 0.5),
];

/// Controls that set the stream's structure — when frames are captured,
/// where keyframes fall, the color layout, and how the sensor samples through
/// the lens. They hold for a whole render (keyframes on the timeline don't
/// animate them).
pub const STRUCTURE_IDS: [&str; 8] = ["frame_rate", "keyframe_interval", "chroma", "fields", "aliasing", "codec", "sensor", "block_size"];

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
    /// 1 keeps full-resolution color, has no deblocking, no motion for a
    /// datamosh to drag, and (here) only the plain patch for lost blocks, no
    /// coefficients for bit errors to damage, blocks of one size and no bit
    /// count for a limit to act on.
    pub fn unused_by(codec: DigitalCodecKind) -> &'static [&'static str] {
        match codec {
            DigitalCodecKind::Dct => &[],
            DigitalCodecKind::BlockColors => &[
                "chroma", "chroma_upsampling", "deblocking", "datamosh", "concealment", "bit_errors", "mosh_motion", "mosh_speed", "block_size", "bitrate_limit", "rate_buffer",
            ],
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

/// The Sensor control: how the camera separates color.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SensorKind {
    /// A prism and a sensor for each of red, green and blue.
    ThreeChips = 0,
    /// One sensor under a mosaic of red, green and blue filters.
    Mosaic = 1,
    /// One sensor under cyan, yellow, magenta and green filters, read two
    /// rows at a time: the 90s one-chip camcorder.
    Complementary = 2,
}

impl SensorKind {
    pub fn from_raw(raw: i64) -> Option<Self> {
        match raw {
            0 => Some(SensorKind::ThreeChips),
            1 => Some(SensorKind::Mosaic),
            2 => Some(SensorKind::Complementary),
            _ => None,
        }
    }
}

/// The Fields control: what becomes of an interlaced camera's two fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FieldMode {
    /// Whole frames, every line from one moment.
    Progressive = 0,
    /// One field, each line shown twice (the chain gets half the lines).
    OneField = 1,
    /// Both fields in one frame: lines alternate between two moments.
    Woven = 2,
    /// Both fields mixed together (a blend deinterlacer).
    Blended = 3,
}

impl FieldMode {
    pub fn from_raw(raw: i64) -> Option<Self> {
        match raw {
            0 => Some(FieldMode::Progressive),
            1 => Some(FieldMode::OneField),
            2 => Some(FieldMode::Woven),
            3 => Some(FieldMode::Blended),
            _ => None,
        }
    }

    /// Two moments in one frame: needs the frame before as well.
    pub fn is_interlaced(self) -> bool {
        self == FieldMode::Woven || self == FieldMode::Blended
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

    /// How the camera separates color.
    pub fn sensor(&self) -> SensorKind {
        SensorKind::from_raw(round_to_int(self.get("sensor"))).unwrap_or(SensorKind::ThreeChips)
    }

    /// How the camera's two fields reach the codec.
    pub fn fields(&self) -> FieldMode {
        FieldMode::from_raw(round_to_int(self.get("fields"))).unwrap_or(FieldMode::Progressive)
    }

    /// The DCT codec's block size in pixels (Video 1's structure is fixed).
    pub fn block_size(&self) -> usize {
        if self.codec() != DigitalCodecKind::Dct {
            return 8;
        }
        [4, 8, 16][swift_min(2, swift_max(0, round_to_int(self.get("block_size")))) as usize]
    }

    pub const LOOSEST_BITS_PER_PIXEL: f64 = 2.0;
    pub const TIGHTEST_BITS_PER_PIXEL: f64 = 0.01;

    /// The Bitrate limit as bits for each pixel of a frame; 0 is no limit.
    /// The slider runs evenly through the ratio: about 2 at its start, 0.01
    /// at 100%.
    pub fn bits_per_pixel(&self) -> f64 {
        let v = swift_min(1.0, self.effective("bitrate_limit"));
        if v <= 0.0 {
            0.0
        } else {
            Self::LOOSEST_BITS_PER_PIXEL * (Self::TIGHTEST_BITS_PER_PIXEL / Self::LOOSEST_BITS_PER_PIXEL).powf(v)
        }
    }

    /// The Bitrate limit in kbps for a capture size and rate, `None` when off.
    pub fn bitrate_kbps(&self, width: usize, height: usize, fps: f64) -> Option<f64> {
        let bpp = self.bits_per_pixel();
        if bpp > 0.0 { Some(bpp * (width * height) as f64 * fps / 1000.0) } else { None }
    }

    /// The same as words for the panel: "≈ 163 kbps at 320 × 240, 15 fps".
    pub fn bitrate_label(&self, width: usize, height: usize, source_fps: f64) -> Option<String> {
        let fps = crate::renderer::DigitalTiming::new(source_fps, self).capture_fps;
        let kbps = self.bitrate_kbps(width, height, fps)?;
        let rate = if kbps >= 1000.0 {
            if kbps >= 10_000.0 { format!("{:.0} Mbps", kbps / 1000.0) } else { format!("{:.1} Mbps", kbps / 1000.0) }
        } else if kbps >= 10.0 {
            format!("{kbps:.0} kbps")
        } else {
            format!("{kbps:.1} kbps")
        };
        Some(format!("≈ {rate} at {width} × {height}, {} fps", fps as i64))
    }

    /// How many more times the picture is compressed (the Generations control).
    pub fn generations(&self) -> usize {
        swift_max(0, round_to_int(self.get("generations"))) as usize
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
