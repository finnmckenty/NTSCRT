//! The timeline: keyframes over the whole look, as on the Mac (`TimelineBar`,
//! `AppState`'s keyframe actions). Keys are whole-state snapshots at a
//! position 0…1; Keyframe sets one at the playhead (or updates the one
//! there); editing while parked on a key updates it; scrubbing never keys.
//! On a clip the timeline is the clip: the playhead is its frame.

use std::collections::HashMap;
use std::time::Instant;

use eframe::egui;
use ntscrt_engine::serde_json::{Map, Value};
use ntscrt_engine::timeline::{Easing, Evaluator, Keyframe, ShaderMeta};

use crate::App;

impl App {
    /// Frames the timeline spans: a clip's own, or duration × fps.
    pub(crate) fn timeline_frames(&self) -> usize {
        match self.video {
            Some(v) => v.total_frames.max(1),
            None => ((self.timeline_seconds * self.timeline_fps as f64).round() as usize).max(1),
        }
    }

    /// How close the playhead must be to a key to count as parked on it.
    fn parked_tolerance(&self) -> f64 {
        if self.video.is_some() { 0.5 / (self.timeline_frames().saturating_sub(1).max(1)) as f64 } else { 1e-6 }
    }

    pub(crate) fn parked_key(&self) -> Option<usize> {
        let tol = self.parked_tolerance();
        self.keys.iter().position(|k| (k.t - self.playhead).abs() < tol)
    }

    /// The evaluator for the current shader (its step grid) and NTSC schema.
    pub(crate) fn evaluator(&mut self) -> Option<Evaluator> {
        self.ensure_shader();
        let meta: HashMap<String, ShaderMeta> = match self.shader_params.get(&self.shader) {
            Some(Ok(ps)) => ps.iter().map(|p| (p.name.clone(), ShaderMeta { minimum: p.minimum, maximum: p.maximum, step: p.step })).collect(),
            _ => HashMap::new(),
        };
        Evaluator::new(&self.keys, meta, &self.ntsc_settings)
    }

    /// Move the playhead and put the animation's values in the controls
    /// (they follow, as when scrubbing in an editor).
    pub(crate) fn scrub(&mut self, t: f64) {
        let mut t = t.clamp(0.0, 1.0);
        // Magnetic: land exactly on a nearby key.
        if let Some(k) = self.keys.iter().min_by(|a, b| (a.t - t).abs().total_cmp(&(b.t - t).abs())) {
            if (k.t - t).abs() < 0.004 {
                t = k.t;
            }
        }
        if let Some(v) = self.video {
            let last = v.total_frames.saturating_sub(1).max(1);
            let frame = (t * last as f64).round() as usize;
            self.video_frame = frame;
            t = frame as f64 / last as f64;
        }
        self.playhead = t;
        self.apply_timeline();
    }

    /// Values at the playhead into the controls.
    pub(crate) fn apply_timeline(&mut self) {
        if !self.timeline_open {
            return;
        }
        let Some(ev) = self.evaluator() else { return };
        let shader = ev.shader(self.playhead);
        if let Some(values) = self.shader_values.get_mut(&self.shader) {
            values.extend(shader);
        }
        let ntsc = ev.ntsc(self.playhead);
        if !ntsc.is_empty() {
            self.ntsc_values = ntsc;
        }
    }

    /// Keep the playhead on the clip's frame (playback, the scrubber).
    pub(crate) fn sync_playhead_to_frame(&mut self) {
        if let (Some(v), true) = (self.video, self.timeline_open) {
            let last = v.total_frames.saturating_sub(1).max(1);
            let t = self.video_frame as f64 / last as f64;
            if (t - self.playhead).abs() > 1e-12 {
                self.playhead = t;
                self.apply_timeline();
            }
        }
    }

    fn snapshot(&self, t: f64) -> Keyframe {
        // Glitch and Digital video aren't ported yet: carry what the look had.
        let section = |k: &str| -> Map<String, Value> {
            self.look_raw.as_ref().and_then(|r| r.get(k)).and_then(|s| s.get("values")).and_then(Value::as_object).cloned().unwrap_or_default()
        };
        Keyframe {
            t,
            easing: Easing::Linear,
            shader: self.shader_values.get(&self.shader).cloned().unwrap_or_default(),
            ntsc: self.ntsc_values.clone(),
            glitch: section("glitch"),
            digital: section("digital"),
        }
    }

    pub(crate) fn set_key_at_playhead(&mut self) {
        let snap = self.snapshot(self.playhead);
        let tol = self.parked_tolerance().max(0.005);
        match self.keys.iter().position(|k| (k.t - self.playhead).abs() < tol) {
            Some(i) => {
                let easing = self.keys[i].easing;
                self.keys[i] = Keyframe { t: self.keys[i].t, easing, ..snap };
                self.selected_key = Some(i);
            }
            None => {
                self.keys.push(snap);
                self.keys.sort_by(|a, b| a.t.total_cmp(&b.t));
                self.selected_key = self.keys.iter().position(|k| k.t == self.playhead);
            }
        }
    }

    /// Editing while parked on a key updates it (not while playing).
    pub(crate) fn auto_key(&mut self) {
        if !self.timeline_open || self.timeline_playing.is_some() || self.playing.is_some() {
            return;
        }
        if let Some(i) = self.parked_key() {
            let snap = self.snapshot(self.keys[i].t);
            let easing = self.keys[i].easing;
            self.keys[i] = Keyframe { easing, ..snap };
        }
    }

    pub(crate) fn toggle_timeline_play(&mut self) {
        if self.video.is_some() {
            self.toggle_play();
            return;
        }
        self.timeline_playing = match self.timeline_playing {
            Some(_) => None,
            None => {
                let from = if self.playhead >= 1.0 { 0.0 } else { self.playhead };
                Some((Instant::now(), from))
            }
        };
    }

    /// A still's timeline plays in real time over its duration, then loops.
    pub(crate) fn advance_timeline(&mut self, ctx: &egui::Context) {
        if let Some((since, from)) = self.timeline_playing {
            let t = from + since.elapsed().as_secs_f64() / self.timeline_seconds.max(0.1);
            let t = if t > 1.0 { t.fract() } else { t };
            if t < self.playhead {
                self.timeline_playing = Some((Instant::now(), t));
            }
            self.playhead = t;
            self.apply_timeline();
            ctx.request_repaint();
        }
    }

    pub(crate) fn timeline_bar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.strong("ANIMATE");
            let playing = self.timeline_playing.is_some() || self.playing.is_some();
            if ui.button(if playing { "Pause" } else { "Play" }).on_hover_text("Space").clicked() {
                self.toggle_timeline_play();
            }
            if ui.button("Keyframe").on_hover_text("Set a keyframe here with everything as it is now, or update the one here.").clicked() {
                self.set_key_at_playhead();
            }
            if let Some(i) = self.selected_key.filter(|i| *i < self.keys.len()) {
                let mut easing = self.keys[i].easing;
                egui::ComboBox::from_id_salt("easing").selected_text(easing.raw()).show_ui(ui, |ui| {
                    for e in Easing::ALL {
                        ui.selectable_value(&mut easing, e, e.raw());
                    }
                });
                self.keys[i].easing = easing;
                if ui.button("Delete keyframe").clicked() {
                    self.keys.remove(i);
                    self.selected_key = None;
                }
            }
            ui.separator();
            if self.video.is_none() {
                ui.label("Duration");
                let before = self.timeline_seconds;
                ui.add(egui::DragValue::new(&mut self.timeline_seconds).range(0.5..=120.0).speed(0.1).suffix(" s"));
                if before != self.timeline_seconds {
                    self.timeline_playing = None;
                }
                egui::ComboBox::from_id_salt("tl-fps").selected_text(format!("{} fps", self.timeline_fps)).show_ui(ui, |ui| {
                    for f in [12, 24, 30, 60] {
                        ui.selectable_value(&mut self.timeline_fps, f, format!("{f} fps"));
                    }
                });
            }
            let frames = self.timeline_frames();
            let frame = (self.playhead * frames.saturating_sub(1) as f64).round() as usize;
            let seconds = match self.video {
                Some(v) => frame as f64 / v.timescale(),
                None => self.playhead * self.timeline_seconds,
            };
            ui.monospace(format!("{:.2} s · frame {}/{}", seconds, frame + 1, frames));
        });

        // The track: ticks, keyframe diamonds (drag to retime, click to
        // select), the playhead (click or drag anywhere else to scrub).
        let (rect, response) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 34.0), egui::Sense::click_and_drag());
        let p = ui.painter_at(rect);
        let visuals = ui.visuals().clone();
        p.rect_filled(rect, 4.0, visuals.extreme_bg_color);
        let x_of = |t: f64| rect.left() + 8.0 + (rect.width() - 16.0) * t as f32;
        let t_of = |x: f32| ((x - rect.left() - 8.0) / (rect.width() - 16.0)).clamp(0.0, 1.0) as f64;
        for i in 0..=10 {
            let x = x_of(i as f64 / 10.0);
            p.line_segment([egui::pos2(x, rect.bottom() - 6.0), egui::pos2(x, rect.bottom())], visuals.widgets.noninteractive.bg_stroke);
        }
        if self.keys.is_empty() {
            p.text(rect.center(), egui::Align2::CENTER_CENTER, "Dial in a look, then press Keyframe to set one", egui::FontId::proportional(12.0), visuals.weak_text_color());
        }
        let mid = rect.center().y;
        for (i, k) in self.keys.iter().enumerate() {
            let c = egui::pos2(x_of(k.t), mid);
            let s = 6.0;
            let pts = vec![c + egui::vec2(0.0, -s), c + egui::vec2(s, 0.0), c + egui::vec2(0.0, s), c + egui::vec2(-s, 0.0)];
            let fill = if Some(i) == self.selected_key { visuals.selection.bg_fill } else { visuals.strong_text_color() };
            p.add(egui::Shape::convex_polygon(pts, fill, egui::Stroke::NONE));
        }
        let px = x_of(self.playhead);
        p.line_segment([egui::pos2(px, rect.top()), egui::pos2(px, rect.bottom())], egui::Stroke::new(2.0, egui::Color32::from_rgb(230, 70, 60)));

        let hit = |pos: egui::Pos2| self.keys.iter().position(|k| (x_of(k.t) - pos.x).abs() < 8.0 && (pos.y - mid).abs() < 10.0);
        if response.drag_started() || response.clicked() {
            if let Some(pos) = response.interact_pointer_pos() {
                self.key_drag = hit(pos);
                if self.key_drag.is_some() {
                    self.selected_key = self.key_drag;
                }
            }
        }
        if let Some(pos) = response.interact_pointer_pos() {
            if response.dragged() || response.clicked() {
                match self.key_drag {
                    Some(i) if response.dragged() && i < self.keys.len() => {
                        self.keys[i].t = t_of(pos.x);
                    }
                    Some(_) => {}
                    None => {
                        self.timeline_playing = None;
                        self.playing = None;
                        self.scrub(t_of(pos.x));
                    }
                }
            }
        }
        if response.drag_stopped() {
            if let Some(i) = self.key_drag.take() {
                // Keep the dragged key selected after re-sorting.
                let moved = self.keys.get(i).map(|k| k.t);
                self.keys.sort_by(|a, b| a.t.total_cmp(&b.t));
                self.selected_key = moved.and_then(|t| self.keys.iter().position(|k| k.t == t));
            }
        }
    }
}
