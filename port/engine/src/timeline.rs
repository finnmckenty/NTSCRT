//! Keyframes and their interpolation: a port of the Mac's `Timeline.swift`
//! (`KeyEasing`, `Keyframe`, `TimelineEvaluator`), same rules.

use std::collections::HashMap;

use serde_json::{Map, Value};

use crate::ntsc_ui::{NtscKind, NtscSetting};

/// Segment easing, carried per keyframe and applied to the segment leaving it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Easing {
    #[default]
    Linear,
    EaseIn,
    EaseOut,
    EaseInOut,
    Hold,
}

impl Easing {
    pub const ALL: [Easing; 5] = [Self::Linear, Self::EaseIn, Self::EaseOut, Self::EaseInOut, Self::Hold];

    /// The name looks store (the Mac's `KeyEasing.rawValue`).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Linear => "Linear",
            Self::EaseIn => "Ease in",
            Self::EaseOut => "Ease out",
            Self::EaseInOut => "Ease in-out",
            Self::Hold => "Hold",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|e| e.raw() == raw)
    }

    pub fn apply(self, u: f64) -> f64 {
        match self {
            Self::Linear => u,
            Self::EaseIn => u * u,
            Self::EaseOut => 1.0 - (1.0 - u) * (1.0 - u),
            Self::EaseInOut => {
                if u < 0.5 {
                    2.0 * u * u
                } else {
                    1.0 - (-2.0 * u + 2.0).powi(2) / 2.0
                }
            }
            Self::Hold => 0.0,
        }
    }
}

/// A whole-state snapshot of every animatable value.
#[derive(Clone, Debug, PartialEq)]
pub struct Keyframe {
    /// Normalized position 0…1.
    pub t: f64,
    pub easing: Easing,
    pub shader: HashMap<String, f32>,
    pub ntsc: Map<String, Value>,
    /// Glitch and Digital video knobs, kept as stored until those stages are
    /// ported (empty in keyframes from before the stages existed).
    pub glitch: Map<String, Value>,
    pub digital: Map<String, Value>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NtscInterp {
    Lerp,
    LerpInt,
    Hold,
}

#[derive(Clone, Copy, Debug)]
pub struct ShaderMeta {
    pub minimum: f32,
    pub maximum: f32,
    pub step: f32,
}

pub struct Evaluator {
    keys: Vec<Keyframe>,
    shader_meta: HashMap<String, ShaderMeta>,
    ntsc_interp: HashMap<String, NtscInterp>,
}

fn interp_table(settings: &[NtscSetting], out: &mut HashMap<String, NtscInterp>) {
    for s in settings {
        let i = match &s.kind {
            NtscKind::Percentage { .. } | NtscKind::Float { .. } => NtscInterp::Lerp,
            NtscKind::Int { .. } => NtscInterp::LerpInt,
            NtscKind::Group { children } | NtscKind::Section { children } => {
                interp_table(children, out);
                NtscInterp::Hold
            }
            NtscKind::Boolean | NtscKind::Enumeration { .. } => NtscInterp::Hold,
        };
        out.insert(s.name.clone(), i);
    }
}

impl Evaluator {
    /// None without keys.
    pub fn new(keys: &[Keyframe], shader_meta: HashMap<String, ShaderMeta>, ntsc: &[NtscSetting]) -> Option<Self> {
        if keys.is_empty() {
            return None;
        }
        let mut keys = keys.to_vec();
        keys.sort_by(|a, b| a.t.total_cmp(&b.t));
        let mut ntsc_interp = HashMap::new();
        interp_table(ntsc, &mut ntsc_interp);
        Some(Self { keys, shader_meta, ntsc_interp })
    }

    /// (a, b, eased progress), clamped outside the first and last keys.
    fn segment(&self, t: f64) -> (&Keyframe, &Keyframe, f64) {
        let (first, last) = (&self.keys[0], &self.keys[self.keys.len() - 1]);
        if t <= first.t || self.keys.len() == 1 {
            return (first, first, 0.0);
        }
        if t >= last.t {
            return (last, last, 0.0);
        }
        let (mut a, mut b) = (first, last);
        for k in &self.keys {
            if k.t <= t {
                a = k;
            } else {
                b = k;
                break;
            }
        }
        let span = b.t - a.t;
        let raw = if span > 0.0 { (t - a.t) / span } else { 0.0 };
        (a, b, a.easing.apply(raw.clamp(0.0, 1.0)))
    }

    pub fn shader(&self, t: f64) -> HashMap<String, f32> {
        let (a, b, u) = self.segment(t);
        if u == 0.0 {
            return a.shader.clone();
        }
        a.shader
            .iter()
            .map(|(name, va)| {
                let vb = b.shader.get(name).copied().unwrap_or(*va);
                let mut v = va + (vb - va) * u as f32;
                if let Some(m) = self.shader_meta.get(name) {
                    if m.step > 0.0 {
                        v = m.minimum + ((v - m.minimum) / m.step).round() * m.step;
                    }
                    v = v.clamp(m.minimum, m.maximum);
                }
                (name.clone(), v)
            })
            .collect()
    }

    pub fn ntsc(&self, t: f64) -> Map<String, Value> {
        let (a, b, u) = self.segment(t);
        if u == 0.0 {
            return a.ntsc.clone();
        }
        a.ntsc
            .iter()
            .map(|(name, va)| {
                let interp = self.ntsc_interp.get(name).copied().unwrap_or(NtscInterp::Hold);
                let v = match (interp, va.as_f64(), b.ntsc.get(name).and_then(Value::as_f64)) {
                    // Booleans aren't numbers in JSON, so they hold.
                    (NtscInterp::Hold, _, _) | (_, None, _) | (_, _, None) => va.clone(),
                    (i, Some(x), Some(y)) => {
                        let v = x + (y - x) * u;
                        if i == NtscInterp::LerpInt { Value::from(v.round() as i64) } else { Value::from(v) }
                    }
                };
                (name.clone(), v)
            })
            .collect()
    }

    /// The keys' stored Glitch and Digital values at `t` (held, not yet
    /// interpolated: those stages aren't ported).
    pub fn first_key(&self) -> &Keyframe {
        &self.keys[0]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(t: f64, easing: Easing, v: f32, n: f64) -> Keyframe {
        let mut ntsc = Map::new();
        ntsc.insert("luma_smear".into(), Value::from(n));
        ntsc.insert("snow_intensity".into(), Value::from(n));
        ntsc.insert("chroma_delay_vertical".into(), Value::from(n.round() as i64));
        ntsc.insert("use_field".into(), Value::from(1));
        ntsc.insert("vhs_settings".into(), Value::Bool(true));
        Keyframe { t, easing, shader: HashMap::from([("BOOST".to_string(), v)]), ntsc, glitch: Map::new(), digital: Map::new() }
    }

    #[test]
    fn interpolates_like_the_mac() {
        let ntsc = crate::ntsc_settings();
        let meta = HashMap::from([("BOOST".to_string(), ShaderMeta { minimum: 0.0, maximum: 2.0, step: 0.05 })]);
        let keys = [key(0.5, Easing::Linear, 2.0, 10.0), key(0.0, Easing::EaseIn, 1.0, 0.0)];
        let ev = Evaluator::new(&keys, meta, &ntsc).unwrap();
        assert_eq!(ev.shader(-1.0)["BOOST"], 1.0, "holds before the first key");
        assert_eq!(ev.shader(2.0)["BOOST"], 2.0, "holds after the last");
        // Ease in at half way: u = 0.25 → 1.25, on the 0.05 grid.
        assert!((ev.shader(0.25)["BOOST"] - 1.25).abs() < 1e-6);
        let n = ev.ntsc(0.25);
        assert_eq!(n["chroma_delay_vertical"], Value::from(3), "ints lerp then round (2.5 → 3)");
        assert_eq!(n["use_field"], Value::from(1), "enums hold");
        assert_eq!(n["vhs_settings"], Value::Bool(true), "booleans hold");
        assert!((n["luma_smear"].as_f64().unwrap() - 2.5).abs() < 1e-9);
        assert_eq!(Easing::Hold.apply(0.9), 0.0);
        assert!((Easing::EaseInOut.apply(0.75) - 0.875).abs() < 1e-12);
    }
}
