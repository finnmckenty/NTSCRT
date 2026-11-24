//! Who made NTSCRT, with the site and X profile as links: Help > About
//! NTSCRT, and as one line in the update prompt (update.rs). The Mac's
//! `AboutPanel.swift`.
//!
//! `NTSCRT_ABOUT=1` opens the window at launch (with `NTSCRT_UI_SNAPSHOT`,
//! for a look at it).

use eframe::egui;

use crate::update;

pub const AUTHOR: &str = "Finn Mckenty";
/// (What the link says, where it goes.)
pub const SITE: (&str, &str) = ("finnmckenty.com", "https://finnmckenty.com");
pub const X: (&str, &str) = ("Finn Mckenty on X", "https://x.com/thefinnmckenty");

/// A link that opens in the browser.
fn link(ui: &mut egui::Ui, item: (&str, &str), small: bool) {
    let text = egui::RichText::new(item.0);
    if ui.link(if small { text.small() } else { text }).on_hover_text(item.1).clicked() {
        update::open_page(item.1);
    }
}

/// One line, small and centered: "NTSCRT by Finn Mckenty · finnmckenty.com ·
/// Finn Mckenty on X", the last two as links.
pub fn credit_line(ui: &mut egui::Ui) {
    let name = format!("NTSCRT by {AUTHOR}");
    let gap = 6.0;
    // Centered by hand: a row lays out left to right from where it starts.
    let font = egui::TextStyle::Small.resolve(ui.style());
    let width = |s: &str| ui.painter().layout_no_wrap(s.to_owned(), font.clone(), egui::Color32::WHITE).size().x;
    let total = width(&name) + [SITE, X].iter().map(|item| width("·") + width(item.0) + 2.0 * gap).sum::<f32>();
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = gap;
        let lead = ((ui.available_width() - total) / 2.0 - gap).max(0.0);
        ui.add_space(lead);
        ui.label(egui::RichText::new(name).small().weak());
        for item in [SITE, X] {
            ui.label(egui::RichText::new("·").small().weak());
            link(ui, item, true);
        }
    });
}

/// Help > About NTSCRT.
pub struct AboutWindow {
    open: bool,
    icon: Option<egui::TextureHandle>,
}

impl AboutWindow {
    pub fn from_env() -> Self {
        Self { open: std::env::var("NTSCRT_ABOUT").as_deref() == Ok("1"), icon: None }
    }

    pub fn open(&mut self) {
        self.open = true;
    }

    pub fn show(&mut self, ctx: &egui::Context) {
        if !self.open {
            return;
        }
        let icon = self.icon.get_or_insert_with(|| {
            let color = match image::load_from_memory(include_bytes!("../icon-256.png")) {
                Ok(img) => {
                    let img = img.to_rgba8();
                    egui::ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw())
                }
                Err(_) => egui::ColorImage::filled([1, 1], egui::Color32::TRANSPARENT),
            };
            ctx.load_texture("about icon", color, egui::TextureOptions::LINEAR)
        });
        let mut open = self.open;
        egui::Window::new("About NTSCRT").open(&mut open).collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0]).show(ctx, |ui| {
            // (Wider than the title bar needs, so the column is centered in the window.)
            ui.set_width(328.0);
            ui.vertical_centered(|ui| {
                ui.add_space(8.0);
                ui.add(egui::Image::new((icon.id(), egui::vec2(72.0, 72.0))));
                ui.add_space(6.0);
                ui.label(egui::RichText::new("NTSCRT").heading().strong());
                ui.label(egui::RichText::new(format!("Version {}", update::current_version())).weak());
                ui.add_space(10.0);
                ui.label(egui::RichText::new(format!("by {AUTHOR}")).strong());
                ui.add_space(2.0);
                link(ui, SITE, false);
                link(ui, X, false);
                ui.add_space(8.0);
            });
        });
        self.open = open;
    }
}
