//! Screen Loop (video feedback, "howlaround"): a camcorder pointed at the TV
//! that shows the camcorder's own picture. A port of the Mac's
//! `Howlaround.swift`: the knobs, the camera's pose and the screen's
//! geometry here; the loop itself (ring of TV pictures, camera kernel, blur)
//! in `feedback.rs`.

pub mod feedback;
pub mod pad;

use std::collections::BTreeMap;

use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Group {
    Framing,
    Movement,
    Camera,
    Signal,
}

impl Group {
    pub const ALL: [Group; 4] = [Group::Framing, Group::Movement, Group::Camera, Group::Signal];

    pub fn label(self) -> &'static str {
        match self {
            Group::Framing => "Framing",
            Group::Movement => "Movement",
            Group::Camera => "Camera",
            Group::Signal => "Signal",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Slider { min: f64, max: f64, percent: bool, unit: &'static str, step: Option<f64> },
    Toggle,
    /// One coordinate of a point dragged on the preview (the vanishing
    /// point, where it drifts to), rather than a knob of its own.
    Position { min: f64, max: f64 },
}

/// For knobs either side of a neutral middle: the words for each side.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sides {
    pub negative: &'static str,
    pub positive: &'static str,
    pub zero: &'static str,
}

/// One knob of the camera. Every knob is something you could do to the real
/// setup: move or turn the camera, defocus it, turn the TV's brightness up,
/// hold the camera in your hand.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Param {
    pub id: &'static str,
    pub label: &'static str,
    pub group: Group,
    pub kind: Kind,
    /// Where a new Screen Loop starts: a tunnel worth looking at.
    pub default_value: f64,
    /// Where the knob's effect is weakest: what a double-click goes to.
    pub neutral_value: f64,
    pub sides: Option<Sides>,
    /// For knobs from none to a lot: what each end of the slider means.
    pub ends: Option<(&'static str, &'static str)>,
    pub help: &'static str,
}

impl Param {
    pub fn is_position(&self) -> bool {
        matches!(self.kind, Kind::Position { .. })
    }

    /// How a value reads: its size and the word for its side ("20", "right"),
    /// or the knob's word for the middle at zero.
    pub fn reading(&self, value: f64) -> (f64, &'static str) {
        let Some(s) = self.sides else { return (value, "") };
        if value.abs() < 1e-9 {
            return (0.0, s.zero);
        }
        (value.abs(), if value < 0.0 { s.negative } else { s.positive })
    }

    pub fn by_id(id: &str) -> Option<&'static Param> {
        PARAMS.iter().find(|p| p.id == id)
    }

    pub fn default_values() -> BTreeMap<String, f64> {
        PARAMS.iter().map(|p| (p.id.to_string(), p.default_value)).collect()
    }
}

const fn slider(min: f64, max: f64, percent: bool, unit: &'static str, step: Option<f64>) -> Kind {
    Kind::Slider { min, max, percent, unit, step }
}

const fn sides(negative: &'static str, positive: &'static str, zero: &'static str) -> Option<Sides> {
    Some(Sides { negative, positive, zero })
}

pub const PARAMS: [Param; 23] = [
    Param {
        id: "zoom", label: "Zoom", group: Group::Framing, kind: slider(0.0, 1.4, true, "", None),
        default_value: 0.87, neutral_value: 0.0, sides: None, ends: Some(("Wide", "Close")),
        help: "How big the TV's screen is in the camera's frame — each copy is this size of the one around it. Below 100% the copies shrink into a tunnel, more of them the closer you get to 100%. Above 100% every pass grows instead, into the swirling patterns feedback is known for. 0% points the camera away from the TV.",
    },
    Param {
        id: "center_x", label: "Vanishing point left – right", group: Group::Framing, kind: Kind::Position { min: -0.5, max: 0.5 },
        default_value: -0.2, neutral_value: 0.0, sides: sides("left", "right", "middle"), ends: None,
        help: "Where the tunnel converges across the frame — the point the copies shrink toward (past 100% zoom, the point they grow away from). It stays put as you change the zoom and angles; the camera is re-aimed at the TV to keep it there. Set by the green dot on the preview.",
    },
    Param {
        id: "center_y", label: "Vanishing point up – down", group: Group::Framing, kind: Kind::Position { min: -0.5, max: 0.5 },
        default_value: -0.22, neutral_value: 0.0, sides: sides("up", "down", "middle"), ends: None,
        help: "Where the tunnel converges up and down the frame. Set by the green dot on the preview.",
    },
    Param {
        id: "roll", label: "Roll", group: Group::Framing, kind: slider(-45.0, 45.0, false, "°", None),
        default_value: 0.0, neutral_value: 0.0, sides: sides("counterclockwise", "clockwise", "level"), ends: None,
        help: "The TV turned against the camera. Every pass turns the picture again, so the tunnel becomes a spiral.",
    },
    Param {
        id: "turn", label: "Side angle", group: Group::Framing, kind: slider(-45.0, 45.0, false, "°", None),
        default_value: -4.0, neutral_value: 0.0, sides: sides("from the left", "from the right", "straight on"), ends: None,
        help: "The camera looking at the screen from one side, so the screen's far edge is narrower. Every pass skews the picture again. At high zoom a steep angle magnifies the near side of the screen enough that part of the picture smears outward instead of forming copies.",
    },
    Param {
        id: "tilt", label: "Vertical angle", group: Group::Framing, kind: slider(-45.0, 45.0, false, "°", None),
        default_value: 0.0, neutral_value: 0.0, sides: sides("from below", "from above", "straight on"), ends: None,
        help: "The camera looking at the screen from above or below.",
    },
    Param {
        id: "shake", label: "Handheld", group: Group::Movement, kind: slider(0.0, 1.0, true, "", None),
        default_value: 0.4, neutral_value: 0.0, sides: None, ends: Some(("Tripod", "Shaky")),
        help: "The camera operator's hands: a slow sway with a little tremor. Every copy is one trip round the loop older than the one around it, so the tunnel follows the camera a moment late and snakes.",
    },
    Param {
        id: "seed", label: "Random seed", group: Group::Movement, kind: slider(1.0, 99.0, false, "", Some(1.0)),
        default_value: 1.0, neutral_value: 1.0, sides: None, ends: None,
        help: "Picks the handheld motion. The same seed always moves the same way — so the draft matches the render, and motion you like can always be found again.",
    },
    Param {
        id: "drift_x", label: "Drift left – right", group: Group::Movement, kind: Kind::Position { min: -1.0, max: 1.0 },
        default_value: 0.0, neutral_value: 0.0, sides: sides("left", "right", "none"), ends: None,
        help: "How far the vanishing point slides across the frame over the render, easing in and out. Set by the blue ring on the preview.",
    },
    Param {
        id: "drift_y", label: "Drift up – down", group: Group::Movement, kind: Kind::Position { min: -1.0, max: 1.0 },
        default_value: 0.0, neutral_value: 0.0, sides: sides("up", "down", "none"), ends: None,
        help: "How far the vanishing point slides up or down over the render. Set by the blue ring on the preview.",
    },
    Param {
        id: "push", label: "Push", group: Group::Movement, kind: slider(-0.5, 0.5, true, "", None),
        default_value: 0.0, neutral_value: 0.0, sides: sides("out", "in", "no push"), ends: None,
        help: "Zooming in or out over the render, from the Zoom you set.",
    },
    Param {
        id: "spin", label: "Spin", group: Group::Movement, kind: slider(-180.0, 180.0, false, "°", None),
        default_value: 0.0, neutral_value: 0.0, sides: sides("counterclockwise", "clockwise", "no spin"), ends: None,
        help: "Rolling the camera over the render, from the Roll you set.",
    },
    Param {
        id: "loop", label: "Seamless loop", group: Group::Movement, kind: Kind::Toggle,
        default_value: 0.0, neutral_value: 0.0, sides: None, ends: None,
        help: "The move goes out and comes back, and the shake repeats over the length — so the file loops without a jump. Made for GIFs.",
    },
    Param {
        id: "focus", label: "Softness", group: Group::Camera, kind: slider(0.0, 1.0, true, "", None),
        default_value: 0.2, neutral_value: 0.0, sides: None, ends: Some(("Sharp", "Soft")),
        help: "The camera's focus on the screen. A little softness on every pass melts the deep copies first; sharp focus keeps the moiré of the screen's dot pattern.",
    },
    Param {
        id: "brightness", label: "Screen brightness", group: Group::Camera, kind: slider(0.5, 1.5, true, "", None),
        default_value: 1.0, neutral_value: 1.0, sides: None, ends: Some(("Fades to black", "Burns to white")),
        help: "How bright the TV looks to the camera — the loop's gain. Below 100% the deep copies fade to black; above, they burn to white.",
    },
    Param {
        id: "contrast", label: "Contrast", group: Group::Camera, kind: slider(0.6, 1.6, true, "", None),
        default_value: 1.05, neutral_value: 1.0, sides: None, ends: Some(("Flatter", "Harsher")),
        help: "The TV's contrast as the camera sees it, applied again on every pass — so the deep copies get harsher (or flatter) than the outer ones.",
    },
    Param {
        id: "color_drift", label: "Color drift", group: Group::Camera, kind: slider(-1.0, 1.0, true, "", None),
        default_value: -0.3, neutral_value: 0.0, sides: sides("cool", "warm", "neutral"), ends: None,
        help: "The camera's white balance against the TV's color temperature. The tint compounds on every pass: cool turns the deep copies teal and blue, warm turns them orange.",
    },
    Param {
        id: "hue_drift", label: "Hue drift", group: Group::Camera, kind: slider(-30.0, 30.0, false, "° per pass", None),
        default_value: 0.0, neutral_value: 0.0, sides: None, ends: None,
        help: "A tint error that turns the hue a little on every pass, so the tunnel cycles through the colors.",
    },
    Param {
        id: "auto_exposure", label: "Auto exposure", group: Group::Camera, kind: slider(0.0, 1.0, true, "", None),
        default_value: 0.0, neutral_value: 0.0, sides: None, ends: Some(("Off", "Hunting")),
        help: "The camcorder's automatic exposure. It reacts to the brightness of its own picture a moment late, so the whole loop pulses.",
    },
    Param {
        id: "key", label: "Luma key", group: Group::Signal, kind: slider(0.0, 1.0, true, "", None),
        default_value: 0.0, neutral_value: 0.0, sides: None, ends: Some(("Off", "Whole picture")),
        help: "A video mixer between the camera and the TV keys your picture over the camera's: its bright parts sit on top, and the feedback shows through the darker parts — so your subject stays solid while the tunnel trails around it. Turn it up to key in darker tones too. Off, the TV shows only what the camera sees.",
    },
    Param {
        id: "key_invert", label: "Key the dark parts", group: Group::Signal, kind: Kind::Toggle,
        default_value: 0.0, neutral_value: 0.0, sides: None, ends: None,
        help: "Key your picture's dark parts on top instead, with the feedback showing through the bright ones — for dark subjects on light backgrounds.",
    },
    Param {
        id: "delay", label: "Delay", group: Group::Signal, kind: slider(1.0, 20.0, false, "frames", Some(1.0)),
        default_value: 1.0, neutral_value: 1.0, sides: None, ends: None,
        help: "How long one trip around the loop takes. Each copy is that much older than the one around it, so anything moving — the camera included — echoes down the tunnel.",
    },
    Param {
        id: "counter", label: "Camcorder counter", group: Group::Signal, kind: Kind::Toggle,
        default_value: 0.0, neutral_value: 0.0, sides: None, ends: None,
        help: "The camcorder's elapsed-time counter, burned into its picture — so it's filmed again with everything else and repeats down the tunnel.",
    },
];

/// A point of the frame in words, to the nearest percent: "20% left, 22%
/// up", "5% down", or "the middle" (from the middle of the frame, fractions
/// of its width and height, y down).
pub fn describe(p: (f64, f64)) -> String {
    let part = |v: f64, id: &str| -> Option<String> {
        let percent = (v.abs() * 100.0).round() as i64;
        let s = Param::by_id(id)?.sides?;
        (percent > 0).then(|| format!("{percent}% {}", if v < 0.0 { s.negative } else { s.positive }))
    };
    let parts: Vec<String> = [part(p.0, "center_x"), part(p.1, "center_y")].into_iter().flatten().collect();
    if parts.is_empty() { "the middle".into() } else { parts.join(", ") }
}

/// Settings saved by earlier versions, in today's terms: until 0.13.1 three
/// ids were spelled the British way, and the drift was a distance and a
/// compass direction (0° right, 90° up).
pub fn migrated(values: &BTreeMap<String, f64>) -> BTreeMap<String, f64> {
    let mut v = values.clone();
    for (old, new) in [("centre_x", "center_x"), ("centre_y", "center_y"), ("colour_drift", "color_drift")] {
        if let Some(x) = v.remove(old) {
            v.entry(new.to_string()).or_insert(x);
        }
    }
    let distance = v.remove("drift");
    let degrees = v.remove("drift_dir");
    if let Some(d) = distance {
        if !v.contains_key("drift_x") && !v.contains_key("drift_y") {
            let a = degrees.unwrap_or(0.0) * std::f64::consts::PI / 180.0;
            let clean = |x: f64| if x.abs() < 1e-12 { 0.0 } else { x };
            v.insert("drift_x".into(), clean(d * a.cos()));
            v.insert("drift_y".into(), clean(-d * a.sin()));
        }
    }
    v
}

/// Where the camera is at one moment. Angles in degrees; the center is where
/// the tunnel converges, from the middle of the frame (fractions, y down).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pose {
    pub zoom: f64,
    pub center_x: f64,
    pub center_y: f64,
    pub roll: f64,
    pub turn: f64,
    pub tilt: f64,
}

type V3 = [f64; 3];

fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn scale(a: V3, k: f64) -> V3 {
    [a[0] * k, a[1] * k, a[2] * k]
}

/// The screen's axes, normal and center in camera space (image plane at
/// z = 1, frame height 1 and width `aspect`, y down).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Screen {
    pub ax: V3,
    pub ay: V3,
    pub n: V3,
    pub c: V3,
}

/// The camera's settings, with the derived quantities the simulation uses.
#[derive(Clone, Debug, PartialEq)]
pub struct HowlSettings {
    pub values: BTreeMap<String, f64>,
}

impl Default for HowlSettings {
    fn default() -> Self {
        Self { values: Param::default_values() }
    }
}

/// How far the operator's hands move the vanishing point at full shake, per
/// unit of their sway (fractions of the frame's width and height).
const HANDHELD_CENTER: (f64, f64) = (0.050, 0.045);

impl HowlSettings {
    /// `values` over the defaults.
    pub fn new(values: &BTreeMap<String, f64>) -> Self {
        let mut v = Param::default_values();
        v.extend(values.iter().map(|(k, x)| (k.clone(), *x)));
        Self { values: v }
    }

    pub fn get(&self, id: &str) -> f64 {
        self.values.get(id).copied().or_else(|| Param::by_id(id).map(|p| p.default_value)).unwrap_or(0.0)
    }

    pub fn zoom(&self) -> f64 {
        self.get("zoom").max(0.0)
    }
    /// Zero zoom: the camera sees the room only, so nothing feeds back.
    pub fn tv_in_view(&self) -> bool {
        self.zoom() > 0.001
    }
    pub fn delay(&self) -> usize {
        (self.get("delay").round() as i64).clamp(1, 20) as usize
    }
    pub fn counter(&self) -> bool {
        self.get("counter") >= 0.5
    }
    pub fn looped(&self) -> bool {
        self.get("loop") >= 0.5
    }
    pub fn seed(&self) -> u64 {
        (self.get("seed").round() as i64).max(1) as u64
    }

    pub fn base_pose(&self) -> Pose {
        Pose {
            zoom: self.zoom(),
            center_x: self.get("center_x"),
            center_y: self.get("center_y"),
            roll: self.get("roll"),
            turn: self.get("turn"),
            tilt: self.get("tilt"),
        }
    }

    pub fn vanishing_point(&self) -> (f64, f64) {
        (self.get("center_x"), self.get("center_y"))
    }
    pub fn drift_target(&self) -> (f64, f64) {
        (self.get("center_x") + self.get("drift_x"), self.get("center_y") + self.get("drift_y"))
    }

    /// The settings that put the vanishing point at `start` and drift it to `end`.
    pub fn point_values(start: (f64, f64), end: (f64, f64)) -> [(&'static str, f64); 4] {
        [("center_x", start.0), ("center_y", start.1), ("drift_x", end.0 - start.0), ("drift_y", end.1 - start.1)]
    }

    /// The furthest the hands take the vanishing point over a render `length`
    /// seconds long, in fractions of the width and height.
    pub fn handheld_reach(&self, length: f64) -> (f64, f64) {
        let shake = self.get("shake");
        if shake <= 0.0 || !self.tv_in_view() {
            return (0.0, 0.0);
        }
        let l = length.max(0.1);
        let hands = Hands::new(self.seed(), self.looped().then_some(l));
        let samples = ((l * 60.0) as i64).clamp(400, 4000);
        let mut reach = (0.0f64, 0.0f64);
        for i in 0..=samples {
            let t = l * i as f64 / samples as f64;
            reach.0 = reach.0.max(hands.value(0, t).abs());
            reach.1 = reach.1.max(hands.value(1, t).abs());
        }
        (shake * HANDHELD_CENTER.0 * reach.0, shake * HANDHELD_CENTER.1 * reach.1)
    }

    /// Where the camera is `t` seconds into a render `length` seconds long:
    /// the framing knobs, then the move (eased, or out and back for a loop),
    /// then the hands. Defined for negative `t` too (the run-up).
    pub fn pose(&self, t: f64, length: f64) -> Pose {
        let mut p = self.base_pose();
        if !self.tv_in_view() {
            return p;
        }
        let l = length.max(0.1);
        let m = if self.looped() {
            let s = (std::f64::consts::PI * t / l).sin();
            s * s
        } else {
            let x = (t / l).clamp(0.0, 1.0);
            x * x * (3.0 - 2.0 * x)
        };
        p.center_x += self.get("drift_x") * m;
        p.center_y += self.get("drift_y") * m;
        p.zoom *= (1.0 + self.get("push") * m).max(0.05);
        p.roll += self.get("spin") * m;
        let shake = self.get("shake");
        if shake > 0.0 {
            let hands = Hands::new(self.seed(), self.looped().then_some(l));
            p.center_x += shake * HANDHELD_CENTER.0 * hands.value(0, t);
            p.center_y += shake * HANDHELD_CENTER.1 * hands.value(1, t);
            p.turn += shake * 6.0 * hands.value(2, t);
            p.tilt += shake * 4.5 * hands.value(3, t);
            p.roll += shake * 3.5 * hands.value(4, t);
            p.zoom *= 1.0 + shake * 0.06 * hands.value(5, t);
        }
        p
    }

    /// The screen for a pose: the camera stays put and the TV turns, placed
    /// so that the point of the TV picture at the tunnel's center is filmed
    /// exactly there (the fixed point the copies shrink toward).
    pub fn screen(pose: &Pose, aspect: f64) -> Screen {
        let deg = std::f64::consts::PI / 180.0;
        let yaw = pose.turn.clamp(-60.0, 60.0) * deg;
        let pitch = pose.tilt.clamp(-60.0, 60.0) * deg;
        let roll = pose.roll * deg;
        let ry = |v: V3| [yaw.cos() * v[0] + yaw.sin() * v[2], v[1], -yaw.sin() * v[0] + yaw.cos() * v[2]];
        let rx = |v: V3| [v[0], pitch.cos() * v[1] - pitch.sin() * v[2], pitch.sin() * v[1] + pitch.cos() * v[2]];
        let rz = |v: V3| [roll.cos() * v[0] - roll.sin() * v[1], roll.sin() * v[0] + roll.cos() * v[1], v[2]];
        let r = |v: V3| ry(rx(rz(v)));
        let ax = r([1.0, 0.0, 0.0]);
        let ay = r([0.0, 1.0, 0.0]);
        let q = [pose.center_x * aspect, pose.center_y, 1.0];
        let offset = scale(add(scale(ax, pose.center_x * aspect), scale(ay, pose.center_y)), pose.zoom);
        let along = (1.0 + offset[2]).max(0.25);
        Screen { ax, ay, n: r([0.0, 0.0, 1.0]), c: add(scale(q, along), scale(offset, -1.0)) }
    }

    /// Where a point of the TV picture (0…1 each way) lands in the camera's
    /// frame (0…1) for a pose, or None behind the camera.
    pub fn camera_point(s: (f64, f64), pose: &Pose, aspect: f64) -> Option<(f64, f64)> {
        let sc = Self::screen(pose, aspect);
        let p = add(add(sc.c, scale(sc.ax, (s.0 - 0.5) * pose.zoom * aspect)), scale(sc.ay, (s.1 - 0.5) * pose.zoom));
        if p[2] <= 1e-4 {
            return None;
        }
        Some((p[0] / p[2] / aspect + 0.5, p[1] / p[2] + 0.5))
    }

    /// The largest factor a pass scales things by at a point (the map's
    /// spectral radius): below 1 the copies shrink toward there.
    fn shrink(&self, s: (f64, f64), aspect: f64) -> Option<f64> {
        let pose = self.base_pose();
        let e = 1e-4;
        let px = Self::camera_point((s.0 + e, s.1), &pose, aspect)?;
        let mx = Self::camera_point((s.0 - e, s.1), &pose, aspect)?;
        let py = Self::camera_point((s.0, s.1 + e), &pose, aspect)?;
        let my = Self::camera_point((s.0, s.1 - e), &pose, aspect)?;
        let jx = ((px.0 - mx.0) / (2.0 * e), (px.1 - mx.1) / (2.0 * e));
        let jy = ((py.0 - my.0) / (2.0 * e), (py.1 - my.1) / (2.0 * e));
        let tr = jx.0 + jy.1;
        let det = jx.0 * jy.1 - jy.0 * jx.1;
        let disc = tr * tr / 4.0 - det;
        if disc >= 0.0 {
            let r = disc.sqrt();
            return Some((tr / 2.0 + r).abs().max((tr / 2.0 - r).abs()));
        }
        Some(det.abs().sqrt())
    }

    /// How deep the tunnel goes: passes until something at its center is
    /// smaller than a couple of scan lines. None when the copies grow.
    pub fn visible_copies(&self, aspect: f64, chain_height: u32) -> Option<usize> {
        if !self.tv_in_view() {
            return Some(0);
        }
        let p = self.base_pose();
        let rate = self.shrink((p.center_x + 0.5, p.center_y + 0.5), aspect)?;
        if rate >= 0.995 {
            return None;
        }
        let n = (2.0 / chain_height.max(16) as f64).ln() / rate.ln();
        Some((n.floor() as i64).clamp(1, 200) as usize)
    }

    /// The run-up before the first frame: `build` trips round the loop at one
    /// frame each, then `settle` frames at the real delay.
    pub fn run_up_plan(&self, aspect: f64, chain_height: u32) -> (usize, usize) {
        if !self.tv_in_view() {
            return (0, 0);
        }
        let copies = self.visible_copies(aspect, chain_height).unwrap_or(60);
        let exposure = if self.get("auto_exposure") > 0.0 { 30 } else { 0 };
        let build = copies + 4 + exposure;
        let settle = if self.looped() { 400.min(self.delay() * (copies + 4).min(12)) } else { self.delay() };
        (build, settle)
    }

    /// The Mac's Screen Loop preset file ("ntscrt-video-feedback", version 2).
    pub fn to_preset(&self, seconds: Option<f64>) -> String {
        let mut m = Map::new();
        m.insert("kind".into(), Value::from(PRESET_KIND));
        m.insert("version".into(), Value::from(2));
        m.insert("values".into(), Value::Object(self.values.iter().map(|(k, v)| (k.clone(), Value::from(*v))).collect()));
        if let Some(s) = seconds {
            m.insert("seconds".into(), Value::from(s));
        }
        serde_json::to_string_pretty(&Value::Object(m)).unwrap_or_default()
    }

    /// A Screen Loop preset: its settings, and a still's length if it has one.
    pub fn from_preset(json: &str) -> anyhow::Result<(Self, Option<f64>)> {
        let v: Value = serde_json::from_str(json)?;
        let values = match (v.get("kind").and_then(Value::as_str), v.get("values").and_then(Value::as_object)) {
            (Some(PRESET_KIND), Some(values)) => values,
            _ => anyhow::bail!("Not a Screen Loop preset. Look presets load from the Preset menu."),
        };
        let values: BTreeMap<String, f64> = values.iter().filter_map(|(k, v)| v.as_f64().map(|f| (k.clone(), f))).collect();
        let seconds = v.get("seconds").and_then(Value::as_f64).map(|s| s.clamp(0.5, 60.0));
        Ok((Self::new(&migrated(&values)), seconds))
    }
}

pub const PRESET_KIND: &str = "ntscrt-video-feedback";

/// The camera operator's hands: per axis, a slow sway (three sinusoids around
/// 0.15–0.7 Hz) with a little tremor (4–7 Hz), the same for the same seed.
/// With a `period` every frequency is a whole number of cycles over it, so
/// the motion repeats exactly (a seamless loop).
pub struct Hands {
    parts: Vec<Vec<(f64, f64, f64)>>,
}

impl Hands {
    pub fn new(seed: u64, period: Option<f64>) -> Self {
        use crate::glitch::receiver::uniform;
        let snap = |f: f64| match period {
            Some(p) => (f * p).round().max(1.0) / p,
            None => f,
        };
        let tau = 2.0 * std::f64::consts::PI;
        let parts = (0..6u64)
            .map(|axis| {
                let mut p = Vec::with_capacity(5);
                let mut power = 0.0;
                for k in 0..3i64 {
                    let u = uniform(seed, 900 + axis, k, 0);
                    let v = uniform(seed, 920 + axis, k, 0);
                    let w = uniform(seed, 940 + axis, k, 0);
                    let amp = 0.5 + 0.5 * w;
                    p.push((snap(0.15 + 0.55 * u), tau * v, amp));
                    power += amp * amp / 2.0;
                }
                // The sway at an RMS of 0.45, then the tremor.
                let s = 0.45 / power.sqrt();
                for x in p.iter_mut() {
                    x.2 *= s;
                }
                for k in 0..2i64 {
                    let u = uniform(seed, 960 + axis, k, 0);
                    let v = uniform(seed, 980 + axis, k, 0);
                    p.push((snap(4.0 + 3.0 * u), tau * v, 0.02));
                }
                p
            })
            .collect();
        Self { parts }
    }

    pub fn value(&self, axis: usize, t: f64) -> f64 {
        self.parts[axis].iter().fold(0.0, |acc, (f, phase, amp)| acc + amp * (2.0 * std::f64::consts::PI * f * t + phase).sin())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_vanishing_point_is_a_fixed_point() {
        // The point of the TV picture at the tunnel's center is filmed there.
        let s = HowlSettings::default();
        for pose in [s.base_pose(), Pose { roll: 20.0, turn: -30.0, tilt: 12.0, ..s.base_pose() }] {
            let tv = (pose.center_x + 0.5, pose.center_y + 0.5);
            let cam = HowlSettings::camera_point(tv, &pose, 16.0 / 9.0).expect("in front");
            assert!((cam.0 - tv.0).abs() < 1e-9 && (cam.1 - tv.1).abs() < 1e-9, "{cam:?} vs {tv:?}");
        }
    }

    #[test]
    fn copies_run_up_and_loops_repeat() {
        let s = HowlSettings::default();
        let copies = s.visible_copies(4.0 / 3.0, 240).expect("a tunnel");
        assert!((10..200).contains(&copies), "{copies}");
        assert_eq!(s.run_up_plan(4.0 / 3.0, 240), (copies + 4, 1));
        let mut zoomed = s.clone();
        zoomed.values.insert("zoom".into(), 1.2);
        assert_eq!(zoomed.visible_copies(4.0 / 3.0, 240), None, "copies grow past 100%");
        zoomed.values.insert("zoom".into(), 0.0);
        assert_eq!(zoomed.run_up_plan(4.0 / 3.0, 240), (0, 0));
        // A seamless loop's hands repeat over its length.
        let h = Hands::new(7, Some(3.0));
        for axis in 0..6 {
            assert!((h.value(axis, 0.4) - h.value(axis, 3.4)).abs() < 1e-9);
        }
        let mut looped = s.clone();
        looped.values.insert("loop".into(), 1.0);
        looped.values.insert("drift_x".into(), 0.3);
        let (a, b) = (looped.pose(0.0, 3.0), looped.pose(3.0, 3.0));
        assert!((a.center_x - b.center_x).abs() < 1e-9 && (a.zoom - b.zoom).abs() < 1e-9);
    }

    #[test]
    fn old_presets_migrate() {
        let old: BTreeMap<String, f64> = [("centre_x", 0.1), ("colour_drift", 0.5), ("drift", 0.2), ("drift_dir", 90.0)]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        let m = migrated(&old);
        assert_eq!(m["center_x"], 0.1);
        assert_eq!(m["color_drift"], 0.5);
        assert_eq!(m["drift_x"], 0.0);
        assert!((m["drift_y"] + 0.2).abs() < 1e-12, "90° is up: toward −y");
        assert_eq!(describe((-0.2, 0.22)), "20% left, 22% down");
        assert_eq!(describe((0.0, 0.0)), "the middle");
    }

    #[test]
    fn the_bundled_presets_load() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../presets/Screen Loop");
        let mut n = 0;
        for e in std::fs::read_dir(dir).expect("folder").flatten() {
            if e.path().extension().is_some_and(|x| x == "json") {
                let json = std::fs::read_to_string(e.path()).unwrap();
                HowlSettings::from_preset(&json).unwrap_or_else(|err| panic!("{}: {err}", e.path().display()));
                n += 1;
            }
        }
        assert!(n >= 4);
    }
}
