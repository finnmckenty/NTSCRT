//! The CRT panel's parameter controls: a port of the Mac's ShaderPanel
//! presentation rules (`presentation(for:)`, `makeSections`) and its
//! `ParamGates` table (why a control does nothing, and what turns it on).

use std::collections::HashMap;

use eframe::egui;
use ntscrt_engine::ShaderParam;

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    /// A label pseudo-parameter (section header or comment).
    Header,
    Toggle,
    Picker { values: Vec<f32>, labels: Option<Vec<String>>, segmented: bool },
    Stepper { step: i32 },
    Slider,
}

#[derive(Clone, Debug)]
pub struct Presentation {
    pub kind: Kind,
    pub title: String,
    pub caption: Option<String>,
}

/// "Curvature Shape [SPHERE, CYLINDER]" → ("Curvature Shape", "SPHERE, CYLINDER").
fn extract_legend(desc: &str) -> (String, Option<String>) {
    let (Some(open), Some(close)) = (desc.find('['), desc.find(']')) else { return (desc.to_string(), None) };
    if close < open {
        return (desc.to_string(), None);
    }
    let legend = &desc[open + 1..close];
    if legend.trim().is_empty() {
        return (desc.to_string(), None);
    }
    let title = format!("{}{}", &desc[..open], &desc[close + 1..]).replace("  ", " ").trim().to_string();
    (title, Some(legend.to_string()))
}

pub fn presentation(p: &ShaderParam) -> Presentation {
    let (lo, hi, step) = (p.minimum as f64, p.maximum as f64, p.step as f64);
    let range = hi - lo;
    let desc = p.description.trim();
    if range <= 0.0 {
        return Presentation { kind: Kind::Header, title: desc.to_string(), caption: None };
    }
    let fallback = if desc.is_empty() { p.name.clone() } else { desc.to_string() };
    if step <= 0.0 {
        return Presentation { kind: Kind::Slider, title: fallback, caption: None };
    }
    let (stripped, legend) = extract_legend(desc);
    let title = if stripped.is_empty() { p.name.clone() } else { stripped };
    let steps = range / step;
    let discrete = (steps - steps.round()).abs() < 1e-3;
    let count = steps.round() as i64 + 1;
    let int_step = step == step.round() && lo == lo.round() && hi == hi.round();

    if discrete && (2..=8).contains(&count) {
        let labels = legend.as_ref().and_then(|l| {
            let t: Vec<String> = l.split(',').map(|s| s.trim().to_string()).collect();
            (t.len() as i64 == count && t.iter().all(|s| !s.is_empty())).then_some(t)
        });
        if count == 2 && lo == 0.0 && hi == 1.0 && int_step && labels.is_none() {
            return Presentation { kind: Kind::Toggle, title, caption: legend };
        }
        let values = (0..count).map(|i| (lo + i as f64 * step) as f32).collect();
        let combined = labels.as_ref().map_or(0, |l| l.iter().map(|s| s.chars().count()).sum());
        let segmented = count <= 4 && combined <= 24;
        let caption = if labels.is_none() { legend } else { None };
        return Presentation { kind: Kind::Picker { values, labels, segmented }, title, caption };
    }
    if int_step && discrete && count <= 32 {
        return Presentation { kind: Kind::Stepper { step: step as i32 }, title, caption: legend };
    }
    Presentation { kind: Kind::Slider, title, caption: legend }
}

pub struct Section<'a> {
    pub title: String,
    pub params: Vec<&'a ShaderParam>,
}

/// Split the flat list at section headers; parameters before the first header
/// stay loose; "//" headers stay inline as captions.
pub fn sections(all: &[ShaderParam]) -> (Vec<&ShaderParam>, Vec<Section<'_>>) {
    let (mut pre, mut out): (Vec<&ShaderParam>, Vec<Section>) = (Vec::new(), Vec::new());
    let mut current: Option<Section> = None;
    for p in all {
        let pres = presentation(p);
        if pres.kind == Kind::Header {
            let title = pres.title.trim().to_string();
            if title.is_empty() {
                out.extend(current.take());
            } else if title.starts_with("//") {
                match &mut current {
                    Some(c) => c.params.push(p),
                    None => pre.push(p),
                }
            } else {
                out.extend(current.take());
                current = Some(Section { title, params: Vec::new() });
            }
        } else {
            match &mut current {
                Some(c) => c.params.push(p),
                None => pre.push(p),
            }
        }
    }
    out.extend(current);
    (pre, out)
}

// MARK: - gates (ParamGates.swift; every rule verified on the Mac with crt-sweep)

#[derive(Clone, Copy)]
enum Condition {
    AtLeast(&'static str, f32),
    Below(&'static str, f32),
    InputHeightAtLeast(u32),
    Never,
}

pub struct Gate {
    condition: Option<Condition>,
    pub hint: &'static str,
}

const fn g(condition: Condition, hint: &'static str) -> Gate {
    Gate { condition: Some(condition), hint }
}
const fn info(hint: &'static str) -> Gate {
    Gate { condition: None, hint }
}

fn table(preset: &str, name: &str) -> Option<Gate> {
    use Condition::*;
    let curvature = |n: &str| matches!(n, "warpX" | "warpY" | "cornersize" | "cornersmooth" | "noise_amt");
    match preset {
        "glow_gauss" | "glow_lanczos" => {
            if curvature(name) {
                Some(g(AtLeast("CURVATURE", 0.5), "Requires Curvature"))
            } else if matches!(name, "maskDark" | "maskLight") {
                Some(g(AtLeast("shadowMask", 0.5), "Requires Mask Effect > 0"))
            } else {
                None
            }
        }
        "hyllian" => match name {
            "GLOW_WHITEPOINT" | "GLOW_ROLLOFF" | "GLOW_RADIUS" | "GLOW_STRENGTH" => {
                Some(g(AtLeast("GLOW_ENABLE", 0.5), "Requires Enable Glow"))
            }
            "h_shape" | "h_radius" | "h_cornersize" | "h_cornersmooth" => Some(g(AtLeast("h_curvature", 0.5), "Requires Curvature")),
            "DISPLAY_RES" => Some(g(AtLeast("PRESET_OPTION", 0.5), "Only used by non-CUSTOM mask presets")),
            "MASK_STRENGTH" => Some(g(Below("PRESET_OPTION", 0.5), "Overridden unless Mask Preset is CUSTOM")),
            "MONITOR_SUBPIXELS" => Some(info("Only affects RGB-triad mask layouts")),
            _ => None,
        },
        "royale" => match name {
            "geom_tilt_angle_x" | "geom_tilt_angle_y" | "geom_view_dist" | "geom_radius" | "aa_cubic_c" => {
                Some(g(AtLeast("geom_mode_runtime", 0.5), "Requires Geometry Mode ≠ flat"))
            }
            "mask_num_triads_desired" => Some(g(AtLeast("mask_specify_num_triads", 0.5), "Requires Specify Number of Triads")),
            "interlace_detect_toggle" | "interlace_bff" => Some(g(InputHeightAtLeast(480), "Needs a ≥480-line input")),
            "interlace_1080i" => Some(g(InputHeightAtLeast(1080), "Needs a 1080-line input")),
            "aa_subpixel_r_offset_x_runtime" | "aa_subpixel_r_offset_y_runtime" | "aa_gauss_sigma" | "beam_horiz_sigma" => {
                Some(g(Never, "Static in this shader build"))
            }
            _ => None,
        },
        "easymode" if name == "MASK_DOT_HEIGHT" => Some(g(AtLeast("MASK_STAGGER", 1.0), "Requires Mask Stagger > 0")),
        "aperture" if name == "SCANLINE_OFFSET" => Some(info("Only shifts at even output÷input scale factors")),
        "sim" if name == "animate_artifacts" => Some(info("Visible with Animate on")),
        _ => None,
    }
}

pub fn gate(preset: &str, p: &ShaderParam) -> Option<Gate> {
    table(preset, &p.name).or_else(|| {
        // Hyllian marks preset-overridden parameters with a leading "*".
        (preset == "hyllian" && p.description.trim().starts_with('*'))
            .then_some(g(Condition::Below("PRESET_OPTION", 0.5), "Overridden unless Mask Preset is CUSTOM"))
    })
}

impl Gate {
    pub fn is_open(&self, values: &HashMap<String, f32>, input_height: Option<u32>) -> bool {
        match self.condition {
            None => true,
            Some(Condition::AtLeast(n, t)) => values.get(n).copied().unwrap_or(0.0) >= t,
            Some(Condition::Below(n, t)) => values.get(n).copied().unwrap_or(0.0) < t,
            Some(Condition::InputHeightAtLeast(l)) => input_height.is_some_and(|h| h >= l),
            Some(Condition::Never) => false,
        }
    }
    pub fn informational(&self) -> bool {
        self.condition.is_none()
    }
}

// MARK: - controls

fn format_choice(v: f32) -> String {
    if v == v.round() { format!("{}", v as i64) } else { format!("{v:.3}").trim_end_matches('0').to_string() }
}

/// One parameter's control. Returns true when the value changed.
pub fn control(ui: &mut egui::Ui, preset: &str, p: &ShaderParam, values: &mut HashMap<String, f32>, input_height: Option<u32>) -> bool {
    let pres = presentation(p);
    if pres.kind == Kind::Header {
        ui.weak(pres.title.trim_start_matches('/').trim());
        return false;
    }
    let gate = gate(preset, p);
    let open = gate.as_ref().is_none_or(|g| g.is_open(values, input_height));
    let mut v = values.get(&p.name).copied().unwrap_or(p.initial);
    let before = v;
    ui.add_enabled_ui(open, |ui| {
        let r = match &pres.kind {
            Kind::Toggle => {
                let mut on = v >= 0.5;
                let r = ui.checkbox(&mut on, &pres.title);
                v = if on { 1.0 } else { 0.0 };
                r
            }
            Kind::Picker { values: choices, labels, segmented } => {
                let label = |i: usize| labels.as_ref().map_or_else(|| format_choice(choices[i]), |l| l[i].clone());
                let current = choices.iter().position(|c| (c - v).abs() < 1e-4);
                ui.label(&pres.title);
                if *segmented {
                    ui.horizontal_wrapped(|ui| {
                        for (i, c) in choices.iter().enumerate() {
                            if ui.selectable_label(current == Some(i), label(i)).clicked() {
                                v = *c;
                            }
                        }
                    })
                    .response
                } else {
                    egui::ComboBox::from_id_salt(&p.name)
                        .selected_text(current.map_or_else(|| format_choice(v), label))
                        .show_ui(ui, |ui| {
                            for (i, c) in choices.iter().enumerate() {
                                if ui.selectable_label(current == Some(i), label(i)).clicked() {
                                    v = *c;
                                }
                            }
                        })
                        .response
                }
            }
            Kind::Stepper { step } => {
                ui.horizontal(|ui| {
                    ui.label(&pres.title);
                    let mut i = v.round() as i32;
                    ui.add(egui::DragValue::new(&mut i).range(p.minimum as i32..=p.maximum as i32).speed(*step.max(&1)));
                    v = i as f32;
                })
                .response
            }
            Kind::Slider | Kind::Header => {
                ui.label(&pres.title);
                let range = p.maximum - p.minimum;
                let step = if p.step > 0.0 && p.step <= range { p.step } else { (range / 100.0).max(1e-4) };
                ui.add(egui::Slider::new(&mut v, p.minimum..=p.maximum).step_by(step as f64))
            }
        };
        r.on_hover_text(format!("{} ({})", pres.title, p.name));
        if let Some(c) = &pres.caption {
            ui.weak(c);
        }
    });
    if let Some(g) = &gate {
        if !open || g.informational() {
            let color = if open { ui.visuals().weak_text_color() } else { egui::Color32::from_rgb(230, 150, 40) };
            ui.colored_label(color, g.hint);
        }
    }
    if v != before {
        values.insert(p.name.clone(), v);
        true
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn param(desc: &str, lo: f32, hi: f32, step: f32) -> ShaderParam {
        ShaderParam { name: "x".into(), description: desc.into(), initial: lo, minimum: lo, maximum: hi, step }
    }

    #[test]
    fn presentation_rules_match_the_mac() {
        assert_eq!(presentation(&param("Curvature", 0.0, 1.0, 1.0)).kind, Kind::Toggle);
        let p = presentation(&param("Curvature Shape [SPHERE, CYLINDER]", 0.0, 1.0, 1.0));
        assert_eq!(p.title, "Curvature Shape");
        assert!(matches!(p.kind, Kind::Picker { labels: Some(ref l), segmented: true, .. } if l == &["SPHERE", "CYLINDER"]));
        // Fractional-step enums (crt-royale's subpixel offsets) are pickers too.
        assert!(matches!(presentation(&param("Offset", -0.333, 0.333, 0.333)).kind, Kind::Picker { .. }));
        assert_eq!(presentation(&param("Layout", 1.0, 17.0, 1.0)).kind, Kind::Stepper { step: 1 });
        let ranged = presentation(&param("Phosphor layout [1-6 APERT, 7-10 DOT]", 1.0, 17.0, 1.0));
        assert_eq!(ranged.caption.as_deref(), Some("1-6 APERT, 7-10 DOT"));
        assert_eq!(presentation(&param("Gamma", 1.0, 3.0, 0.05)).kind, Kind::Slider);
        assert_eq!(presentation(&param("COLOR SETTINGS:", 0.0, 0.0, 0.0)).kind, Kind::Header);
    }
}
