//! NTSCRT for Windows — first skeleton: open a picture, NTSC on/off, the
//! Downscale, a CRT shader, and a live preview. Rendering runs on a worker
//! thread that owns the engine; the window shows the latest frame.
//!
//! Hooks (for checking it headlessly):
//! - `NTSCRT_SOURCE=<image>` (or a path argument): open it at launch.
//! - `NTSCRT_UI_SNAPSHOT=<png>`: once the first frame is on screen, save a
//!   screenshot of the window there and quit.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Instant;

use eframe::egui;
use ntscrt_engine::{
    app_shader_defaults, find_shaders, DownscaleMethod, DownscaleSpec, Engine, Image, NtscSettings, Settings, ShaderSpec,
    CRT_SHADERS,
};

enum Request {
    Source(Image),
    Render { seq: u64, settings: Settings, output: (u32, u32) },
}

struct Rendered {
    seq: u64,
    result: Result<Image, String>,
    millis: u128,
}

fn worker(requests: Receiver<Request>, results: Sender<Rendered>, info: Sender<String>, ctx: egui::Context) {
    let mut engine = match Engine::new() {
        Ok(e) => e,
        Err(e) => {
            let _ = info.send(format!("No graphics device: {e}"));
            return;
        }
    };
    let a = engine.adapter_info();
    let _ = info.send(format!("{} ({:?})", a.name, a.backend));
    ctx.request_repaint();
    while let Ok(first) = requests.recv() {
        // Take everything waiting: new pictures in order, only the latest render.
        let mut render = None;
        for r in std::iter::once(first).chain(requests.try_iter()) {
            match r {
                Request::Source(img) => engine.set_source(img),
                r @ Request::Render { .. } => render = Some(r),
            }
        }
        if let Some(Request::Render { seq, settings, output }) = render {
            let t = Instant::now();
            let result = engine.render(&settings, output).map_err(|e| format!("{e:#}"));
            let _ = results.send(Rendered { seq, result, millis: t.elapsed().as_millis() });
            ctx.request_repaint();
        }
    }
}

struct App {
    requests: Sender<Request>,
    results: Receiver<Rendered>,
    info: Receiver<String>,
    adapter: String,
    shaders: Option<PathBuf>,

    source: Option<(String, u32, u32)>,
    downscale: bool,
    downscale_width: u32,
    method: DownscaleMethod,
    ntsc: bool,
    crt: bool,
    shader: usize,

    seq: u64,
    sent: Option<(Settings, (u32, u32))>,
    texture: Option<egui::TextureHandle>,
    shown_seq: u64,
    status: String,
    error: Option<String>,

    snapshot: Option<PathBuf>,
    snapshot_requested: bool,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> Self {
        let (req_tx, req_rx) = channel();
        let (res_tx, res_rx) = channel();
        let (info_tx, info_rx) = channel();
        let ctx = cc.egui_ctx.clone();
        std::thread::spawn(move || worker(req_rx, res_tx, info_tx, ctx));
        let mut app = Self {
            requests: req_tx,
            results: res_rx,
            info: info_rx,
            adapter: "starting…".into(),
            shaders: find_shaders(),
            source: None,
            downscale: true,
            downscale_width: 320,
            method: DownscaleMethod::Nearest,
            ntsc: true,
            crt: true,
            shader: CRT_SHADERS.iter().position(|s| s.0 == "glow_gauss").unwrap_or(0),
            seq: 0,
            sent: None,
            texture: None,
            shown_seq: 0,
            status: String::new(),
            error: None,
            snapshot: std::env::var_os("NTSCRT_UI_SNAPSHOT").map(PathBuf::from),
            snapshot_requested: false,
        };
        let start = std::env::args_os().nth(1).map(PathBuf::from).or_else(|| std::env::var_os("NTSCRT_SOURCE").map(PathBuf::from));
        if let Some(p) = start {
            app.open(&p);
        }
        app
    }

    fn open(&mut self, path: &Path) {
        match image::open(path) {
            Ok(img) => {
                let img = img.to_rgba8();
                let (w, h) = img.dimensions();
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                self.source = Some((name, w, h));
                let _ = self.requests.send(Request::Source(Image::new(w, h, img.into_raw())));
                self.sent = None;
                self.error = None;
            }
            Err(e) => self.error = Some(format!("Couldn't open {}: {e}", path.display())),
        }
    }

    fn settings(&self, source: (u32, u32)) -> Settings {
        let shader = match (&self.shaders, self.crt) {
            (Some(root), true) => {
                let (id, _, rel) = CRT_SHADERS[self.shader];
                Some(ShaderSpec { preset: root.join(rel), params: app_shader_defaults(id) })
            }
            _ => None,
        };
        Settings {
            ntsc: self.ntsc.then_some(NtscSettings::Default),
            downscale: self.downscale.then(|| DownscaleSpec::for_width(self.downscale_width, source, self.method)),
            shader,
            frame: 1,
        }
    }

    fn sidebar(&mut self, ui: &mut egui::Ui) {
        ui.add_space(6.0);
        ui.heading("Source");
        ui.horizontal(|ui| {
            if ui.button("Open…").clicked() {
                if let Some(p) = rfd::FileDialog::new().add_filter("Images", &["png", "jpg", "jpeg"]).pick_file() {
                    self.open(&p);
                }
            }
        });
        match &self.source {
            Some((name, w, h)) => {
                ui.label(name);
                ui.weak(format!("{w} × {h} px"));
            }
            None => {
                ui.weak("Open an image, or drop one on the window.");
            }
        }
        ui.separator();

        ui.checkbox(&mut self.downscale, egui::RichText::new("Downscale").heading());
        ui.add_enabled_ui(self.downscale, |ui| {
            ui.horizontal(|ui| {
                ui.label("Width");
                ui.add(egui::DragValue::new(&mut self.downscale_width).range(64..=1920).suffix(" px"));
            });
            if let Some((_, w, h)) = self.source {
                let spec = DownscaleSpec::for_width(self.downscale_width, (w, h), self.method);
                ui.weak(format!("Resolution: {} × {}", spec.width, spec.height));
            }
            ui.horizontal(|ui| {
                ui.label("Sampling");
                ui.selectable_value(&mut self.method, DownscaleMethod::Nearest, "Chunky")
                    .on_hover_text("One source pixel per block: hard pixel edges.");
                ui.selectable_value(&mut self.method, DownscaleMethod::Area, "Smooth")
                    .on_hover_text("The average of the whole block: softer, steady.");
            });
        });
        ui.separator();

        ui.checkbox(&mut self.ntsc, egui::RichText::new("NTSC (TV)").heading());
        ui.weak("ntsc-rs's default settings for now.");
        ui.separator();

        ui.checkbox(&mut self.crt, egui::RichText::new("CRT").heading());
        ui.add_enabled_ui(self.crt, |ui| {
            egui::ComboBox::from_id_salt("shader")
                .selected_text(CRT_SHADERS[self.shader].1)
                .show_ui(ui, |ui| {
                    for (i, s) in CRT_SHADERS.iter().enumerate() {
                        ui.selectable_value(&mut self.shader, i, s.1);
                    }
                });
        });
        if self.shaders.is_none() {
            ui.colored_label(egui::Color32::LIGHT_RED, "Shaders not found (set NTSCRT_SHADERS).");
        }

        ui.with_layout(egui::Layout::bottom_up(egui::Align::LEFT), |ui| {
            ui.add_space(4.0);
            ui.weak(&self.status);
            ui.weak(format!("GPU: {}", self.adapter));
        });
    }

    fn preview(&mut self, ui: &mut egui::Ui) {
        let Some((_, w, h)) = self.source else {
            ui.centered_and_justified(|ui| ui.label("Open an image (or drop one here) to start."));
            return;
        };
        let avail = ui.available_rect_before_wrap();
        let aspect = w as f32 / h as f32;
        let mut size = avail.size();
        if size.x / size.y > aspect { size.x = size.y * aspect } else { size.y = size.x / aspect }
        let rect = egui::Rect::from_center_size(avail.center(), size);
        let ppp = ui.ctx().pixels_per_point();
        let output = (((size.x * ppp).round() as u32).max(16), ((size.y * ppp).round() as u32).max(16));

        let settings = self.settings((w, h));
        let want = (settings, output);
        if self.sent.as_ref() != Some(&want) {
            self.seq += 1;
            let _ = self.requests.send(Request::Render { seq: self.seq, settings: want.0.clone(), output });
            self.sent = Some(want);
        }

        if let Some(tex) = &self.texture {
            ui.painter().image(tex.id(), rect, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), egui::Color32::WHITE);
        }
        if let Some(e) = &self.error {
            ui.painter().text(avail.left_top() + egui::vec2(8.0, 8.0), egui::Align2::LEFT_TOP, e, egui::FontId::proportional(14.0), egui::Color32::LIGHT_RED);
        }
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        for a in self.info.try_iter() {
            self.adapter = a;
        }
        for r in self.results.try_iter() {
            match r.result {
                Ok(img) => {
                    let color = egui::ColorImage::from_rgba_unmultiplied([img.width as usize, img.height as usize], &img.rgba);
                    match &mut self.texture {
                        Some(t) => t.set(color, egui::TextureOptions::NEAREST),
                        None => self.texture = Some(ctx.load_texture("preview", color, egui::TextureOptions::NEAREST)),
                    }
                    self.shown_seq = r.seq;
                    self.status = format!("{} × {}, rendered in {} ms", img.width, img.height, r.millis);
                    self.error = None;
                }
                Err(e) => self.error = Some(e),
            }
        }
        let dropped = ctx.input(|i| i.raw.dropped_files.iter().map(|f| f.path().to_path_buf()).find(|p| !p.as_os_str().is_empty()));
        if let Some(p) = dropped {
            self.open(&p);
        }

        egui::Panel::left("sidebar").resizable(false).exact_size(250.0).show(ui, |ui| self.sidebar(ui));
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(egui::Color32::from_rgb(13, 13, 15)))
            .show(ui, |ui| self.preview(ui));

        // NTSCRT_UI_SNAPSHOT: screenshot once the latest request is on screen.
        if let Some(path) = self.snapshot.clone() {
            if !self.snapshot_requested && self.shown_seq != 0 && self.shown_seq == self.seq {
                self.snapshot_requested = true;
                let close = ctx.clone();
                ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |image| {
                    let [w, h] = image.size;
                    let rgba: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_array()).collect();
                    if let Some(buf) = image::RgbaImage::from_raw(w as u32, h as u32, rgba) {
                        let _ = buf.save(&path);
                    }
                    close.send_viewport_cmd(egui::ViewportCommand::Close);
                    close.request_repaint();
                })));
            } else if self.error.is_some() && self.source.is_some() {
                eprintln!("error: {}", self.error.as_deref().unwrap_or_default());
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_title("NTSCRT (Windows preview)").with_inner_size([1200.0, 780.0]),
        ..Default::default()
    };
    eframe::run_native("NTSCRT", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}
