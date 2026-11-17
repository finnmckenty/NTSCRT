//! The "Connect to Claude" window (Help menu; the Mac's `ConnectClaudeView`).

use std::path::PathBuf;

use eframe::egui;

use crate::claude::{self, Status};

pub struct ConnectWindow {
    open: bool,
    desktop: Status,
    code: Status,
    message: Option<(String, bool)>,
    /// NTSCRT_CONNECT_SELFTEST: open at launch, snapshot the window here, quit.
    snapshot: Option<PathBuf>,
    frames: u32,
}

impl ConnectWindow {
    pub fn from_env() -> Self {
        let snapshot = std::env::var_os("NTSCRT_CONNECT_SELFTEST").map(PathBuf::from);
        let mut w = Self { open: false, desktop: Status::NotInstalled, code: Status::NotInstalled, message: None, snapshot, frames: 0 };
        if w.snapshot.is_some() {
            w.open();
        }
        w
    }

    pub fn open(&mut self) {
        self.open = true;
        self.refresh();
    }

    fn refresh(&mut self) {
        self.desktop = claude::desktop_status();
        self.code = claude::code_status();
    }

    pub fn show(&mut self, ctx: &egui::Context) {
        if !self.open {
            return;
        }
        let mut open = self.open;
        let problem = claude::location_problem();
        egui::Window::new("Connect to Claude").open(&mut open).resizable(false).collapsible(false).default_width(440.0).show(ctx, |ui| {
            ui.set_width(440.0);
            ui.label("Lets Claude use NTSCRT: describe a look in words, and Claude previews frames, adjusts the settings, renders the video and can save the look as a preset. Rendering happens on this PC; Claude sees the preview frames it asks for.");
            if let Some(p) = &problem {
                ui.add_space(6.0);
                ui.colored_label(egui::Color32::from_rgb(230, 150, 40), p.as_str());
            }
            ui.add_space(10.0);
            let desktop = self.desktop.clone();
            self.row(
                ui,
                "Claude Desktop",
                &desktop,
                "Claude Desktop isn't installed.",
                problem.is_some(),
                || claude::connect_desktop().map(|_| "Connected. Quit Claude Desktop (in the system tray too, or File > Exit) and open it again to use NTSCRT.".into()),
                || claude::disconnect_desktop().map(|_| "Disconnected. Quit and reopen Claude Desktop for it to take effect.".into()),
            );
            ui.add_space(8.0);
            let code = self.code.clone();
            self.row(
                ui,
                "Claude Code",
                &code,
                "The `claude` command wasn't found. If you use Claude Code, run this in a terminal:",
                problem.is_some(),
                || claude::connect_code().map(|_| "Connected. New Claude Code sessions can use NTSCRT.".into()),
                || claude::disconnect_code().map(|_| "Disconnected from Claude Code.".into()),
            );
            if code == Status::NotInstalled {
                let command = claude::code_command();
                ui.horizontal(|ui| {
                    ui.add(egui::Label::new(egui::RichText::new(&command).monospace().small()).wrap());
                    if ui.button("Copy").clicked() {
                        ui.ctx().copy_text(command.clone());
                    }
                });
            }
            if let Some((text, is_error)) = &self.message {
                ui.add_space(8.0);
                if *is_error {
                    ui.colored_label(egui::Color32::LIGHT_RED, text);
                } else {
                    ui.label(text);
                }
            }
            ui.add_space(10.0);
            ui.weak("To use it, give Claude a file's path (in File Explorer: select it and press Ctrl+Shift+C), then describe the look. Videos are saved in Videos › NTSCRT.");
        });
        self.open = open;

        if let Some(path) = self.snapshot.clone() {
            self.frames += 1;
            ctx.request_repaint();
            if self.frames == 4 {
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
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn row(
        &mut self,
        ui: &mut egui::Ui,
        title: &str,
        status: &Status,
        missing: &str,
        blocked: bool,
        connect: impl FnOnce() -> Result<String, String>,
        disconnect: impl FnOnce() -> Result<String, String>,
    ) {
        let mut action: Option<Result<String, String>> = None;
        ui.horizontal(|ui| {
            ui.strong(title);
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| match status {
                Status::Connected => {
                    if ui.button("Disconnect").clicked() {
                        action = Some(disconnect());
                    }
                    ui.colored_label(egui::Color32::from_rgb(80, 200, 120), "Connected");
                }
                Status::NotConnected | Status::ConnectedElsewhere(_) => {
                    if ui.add_enabled(!blocked, egui::Button::new("Connect")).clicked() {
                        action = Some(connect());
                    }
                }
                Status::NotInstalled | Status::Unreadable(_) => {}
            });
        });
        match status {
            Status::NotInstalled => {
                ui.weak(missing);
            }
            Status::ConnectedElsewhere(other) => {
                ui.weak(format!("Connected to an NTSCRT at another location ({other}). Connect to use this one."));
            }
            Status::Unreadable(why) => {
                ui.colored_label(egui::Color32::LIGHT_RED, why);
            }
            _ => {}
        }
        if let Some(r) = action {
            self.message = Some(match r {
                Ok(m) => (m, false),
                Err(e) => (e, true),
            });
            self.refresh();
        }
    }
}
