use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::svg::{tiny_skia, usvg, SvgDocument};
use crate::view::ViewState;

const MIN_SCALE: f32 = 0.01;
const MAX_SCALE: f32 = 100.0;

/// Screen pixels per second of keyboard-driven panning.
const KEY_PAN_SPEED: f32 = 600.0;

/// Multiplicative zoom step applied per `+`/`-` key press.
const KEY_ZOOM_STEP: f32 = 1.25;

/// How long a reload-error banner stays visible before fading.
const ERROR_BANNER_DURATION: Duration = Duration::from_secs(6);

/// How long to wait after the last zoom tick before doing a full re-rasterize.
/// While this window is open, the last-rendered texture is just drawn stretched
/// to the live size instead — cheap, and keeps zooming smooth even on complex SVGs.
const ZOOM_SETTLE_DELAY: Duration = Duration::from_millis(120);

/// Hard cap on rasterization resolution, independent of how far the user has
/// zoomed. Without this, zooming in on a document with a large native size
/// could balloon the texture up to `max_texture_side` (potentially 8k-16k px,
/// i.e. hundreds of MB), making every re-render and every GPU upload slow.
const MAX_RASTER_DIMENSION: u32 = 4096;

#[derive(PartialEq, Clone, Copy)]
struct CropRect {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

#[derive(PartialEq, Clone, Copy)]
struct RasterKey {
    px_width: u32,
    px_height: u32,
    generation: u64,
    /// SVG-space region being rasterized when zoomed in past the resolution
    /// cap; `None` means the whole document (the common case, and cheap to
    /// keep rendered since it doesn't change as the user pans).
    crop: Option<CropRect>,
}

pub struct SvgViewerApp {
    path: PathBuf,
    document: SvgDocument,
    background: Option<tiny_skia::Color>,
    view: ViewState,
    generation: u64,
    texture: Option<egui::TextureHandle>,
    /// SVG-space rect (in document user-units) that `texture` currently
    /// depicts. `min` is `(0, 0)` when the texture holds the whole document.
    texture_rect: Option<egui::Rect>,
    last_key: Option<RasterKey>,
    reload_rx: Receiver<()>,
    last_interaction: Instant,
    fontdb: Arc<usvg::fontdb::Database>,
    /// Message and timestamp of the most recent failed reload, shown as an
    /// in-window banner since stderr isn't visible when launched from an editor.
    reload_error: Option<(String, Instant)>,
}

impl SvgViewerApp {
    pub fn new(
        path: PathBuf,
        document: SvgDocument,
        background: Option<tiny_skia::Color>,
        reload_rx: Receiver<()>,
        fontdb: Arc<usvg::fontdb::Database>,
    ) -> Self {
        Self {
            path,
            document,
            background,
            view: ViewState::default(),
            generation: 0,
            texture: None,
            texture_rect: None,
            last_key: None,
            reload_rx,
            last_interaction: Instant::now() - ZOOM_SETTLE_DELAY,
            fontdb,
            reload_error: None,
        }
    }

    /// Drains the file-watcher channel; on a signal, tries to reload the SVG.
    /// A failed reload keeps showing the last-good document instead of crashing.
    /// The current pan/zoom is preserved across reloads so you can watch a
    /// zoomed-in detail update as you edit.
    fn poll_reload(&mut self) {
        let mut changed = false;
        while self.reload_rx.try_recv().is_ok() {
            changed = true;
        }
        if !changed {
            return;
        }

        match SvgDocument::load(&self.path, self.fontdb.clone()) {
            Ok(doc) => {
                self.document = doc;
                self.generation += 1;
                self.reload_error = None;
            }
            Err(err) => {
                let message = format!("failed to reload {}: {err:#}", self.path.display());
                eprintln!("warning: {message}");
                self.reload_error = Some((message, Instant::now()));
            }
        }
    }
}

impl eframe::App for SvgViewerApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.poll_reload();

        egui::Frame::central_panel(ui.style()).show(ui, |ui| {
            let avail_rect = ui.available_rect_before_wrap();
            let avail_size = avail_rect.size();
            if avail_size.x <= 0.0 || avail_size.y <= 0.0 {
                return;
            }

            let (svg_w, svg_h) = self.document.size();
            let svg_size = egui::vec2(svg_w.max(1.0), svg_h.max(1.0));

            self.view.refit(svg_size, avail_size);

            let response =
                ui.interact(avail_rect, ui.id().with("svg_canvas"), egui::Sense::click_and_drag());

            if response.dragged() {
                self.view.pan(response.drag_delta());
                self.last_interaction = Instant::now();
            }
            if let Some(hover_pos) = response.hover_pos() {
                let scroll_y = ui.input(|i| i.smooth_scroll_delta.y);
                if scroll_y != 0.0 {
                    let factor = (scroll_y * 0.0025).exp();
                    let cursor_local = hover_pos - avail_rect.min;
                    self.view.zoom(factor, cursor_local, MIN_SCALE, MAX_SCALE);
                    self.last_interaction = Instant::now();
                }
            }

            // Keyboard controls: arrow keys pan, +/- zoom around the canvas
            // center, and R (or 0) resets back to fit-to-window.
            let (pan_dir, zoom_in, zoom_out, reset, dt) = ui.input(|i| {
                let mut dir = egui::Vec2::ZERO;
                if i.key_down(egui::Key::ArrowLeft) {
                    dir.x += 1.0;
                }
                if i.key_down(egui::Key::ArrowRight) {
                    dir.x -= 1.0;
                }
                if i.key_down(egui::Key::ArrowUp) {
                    dir.y += 1.0;
                }
                if i.key_down(egui::Key::ArrowDown) {
                    dir.y -= 1.0;
                }
                (
                    dir,
                    i.key_pressed(egui::Key::Plus) || i.key_pressed(egui::Key::Equals),
                    i.key_pressed(egui::Key::Minus),
                    i.key_pressed(egui::Key::R) || i.key_pressed(egui::Key::Num0),
                    i.stable_dt,
                )
            });

            if reset {
                self.view = ViewState::default();
                self.view.refit(svg_size, avail_size);
            } else {
                if pan_dir != egui::Vec2::ZERO {
                    self.view.pan(pan_dir.normalized() * KEY_PAN_SPEED * dt);
                    self.last_interaction = Instant::now();
                    ui.ctx().request_repaint();
                }
                if zoom_in || zoom_out {
                    let factor = if zoom_in { KEY_ZOOM_STEP } else { 1.0 / KEY_ZOOM_STEP };
                    self.view.zoom(factor, avail_size / 2.0, MIN_SCALE, MAX_SCALE);
                    self.last_interaction = Instant::now();
                }
            }

            // `avail_size`/`self.view.scale` are in egui's logical points, but the
            // texture needs to be sized in physical pixels or it comes out
            // under-resolved (and gets blurrily upscaled by the GPU) on any
            // HiDPI display, where `pixels_per_point` > 1.
            let pixels_per_point = ui.ctx().pixels_per_point();
            let raster_scale = self.view.scale * pixels_per_point;

            let max_texture_side = ui.ctx().input(|i| i.max_texture_side).max(1) as u32;
            let raster_limit = max_texture_side.min(MAX_RASTER_DIMENSION);

            // Ideal, uncapped resolution needed to rasterize the *whole*
            // document crisply at the current zoom.
            let ideal_width = svg_size.x * raster_scale;
            let ideal_height = svg_size.y * raster_scale;

            let (px_width, px_height, svg_rect, crop) = if ideal_width <= raster_limit as f32
                && ideal_height <= raster_limit as f32
            {
                // Fits within the cap: rasterize the whole document. Panning
                // and zooming then just reposition/rescale this same texture
                // (cheap), since its content doesn't depend on either.
                let px_width = (ideal_width.round() as u32).clamp(1, raster_limit);
                let px_height = (ideal_height.round() as u32).clamp(1, raster_limit);
                let rect = egui::Rect::from_min_size(egui::Pos2::ZERO, svg_size);
                (px_width, px_height, rect, None)
            } else {
                // Too zoomed in for the whole document to stay crisp within
                // the resolution cap. Rasterize just the visible viewport at
                // full resolution instead of downsampling the whole document
                // into a capped-size texture, which would look blurry.
                let px_width =
                    ((avail_size.x * pixels_per_point).round() as u32).clamp(1, raster_limit);
                let px_height =
                    ((avail_size.y * pixels_per_point).round() as u32).clamp(1, raster_limit);
                let min = egui::pos2(
                    -self.view.offset.x / self.view.scale,
                    -self.view.offset.y / self.view.scale,
                );
                let size = avail_size / self.view.scale;
                let rect = egui::Rect::from_min_size(min, size);
                let crop = CropRect {
                    x: rect.min.x,
                    y: rect.min.y,
                    w: rect.width(),
                    h: rect.height(),
                };
                (px_width, px_height, rect, Some(crop))
            };

            let key = RasterKey {
                px_width,
                px_height,
                generation: self.generation,
                crop,
            };
            // The draw rect below always reflects the live scale/offset (cheap: it's
            // just a GPU-side stretch/reposition of whatever texture we already
            // have), so it's safe to defer the actual re-rasterize until the
            // pan/zoom gesture settles.
            let settled = self.last_interaction.elapsed() >= ZOOM_SETTLE_DELAY;
            if self.last_key != Some(key) {
                if self.texture.is_none() || settled {
                    let pixmap = match crop {
                        None => self.document.rasterize(px_width, px_height, self.background),
                        Some(_) => {
                            let region = tiny_skia::Rect::from_xywh(
                                svg_rect.min.x,
                                svg_rect.min.y,
                                svg_rect.width(),
                                svg_rect.height(),
                            )
                            .expect("crop rect has positive, finite size");
                            self.document.rasterize_region(
                                region,
                                px_width,
                                px_height,
                                self.background,
                            )
                        }
                    };
                    let color_image = egui::ColorImage::from_rgba_premultiplied(
                        [pixmap.width() as usize, pixmap.height() as usize],
                        pixmap.data(),
                    );
                    match &mut self.texture {
                        Some(tex) => tex.set(color_image, egui::TextureOptions::LINEAR),
                        None => {
                            self.texture = Some(ui.ctx().load_texture(
                                "svg-content",
                                color_image,
                                egui::TextureOptions::LINEAR,
                            ));
                        }
                    }
                    self.last_key = Some(key);
                    self.texture_rect = Some(svg_rect);
                } else {
                    // Still mid-gesture: make sure a frame fires once the settle
                    // delay elapses so the final, crisp re-rasterize actually
                    // happens even if the user stops interacting without any
                    // further input.
                    ui.ctx().request_repaint_after(ZOOM_SETTLE_DELAY);
                }
            }

            if let (Some(texture), Some(tex_rect)) = (&self.texture, self.texture_rect) {
                // Map the SVG-space rect the texture depicts through the
                // *live* scale/offset, so it stays correctly placed even
                // while a fresh rasterize is deferred mid-gesture.
                let image_rect = egui::Rect::from_min_size(
                    avail_rect.min + self.view.offset + tex_rect.min.to_vec2() * self.view.scale,
                    tex_rect.size() * self.view.scale,
                );
                ui.painter().image(
                    texture.id(),
                    image_rect,
                    egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)),
                    egui::Color32::WHITE,
                );
            }

            // Reload errors only go to stderr otherwise, which is invisible
            // when the viewer is launched from an editor/script rather than
            // a visible terminal.
            if let Some((message, at)) = &self.reload_error {
                let elapsed = at.elapsed();
                if elapsed < ERROR_BANNER_DURATION {
                    let banner_rect = egui::Rect::from_min_size(
                        avail_rect.min,
                        egui::vec2(avail_size.x, 28.0),
                    );
                    ui.painter().rect_filled(
                        banner_rect,
                        0.0,
                        egui::Color32::from_rgba_unmultiplied(178, 34, 34, 230),
                    );
                    ui.painter().text(
                        banner_rect.left_center() + egui::vec2(10.0, 0.0),
                        egui::Align2::LEFT_CENTER,
                        message,
                        egui::FontId::proportional(14.0),
                        egui::Color32::WHITE,
                    );
                    ui.ctx()
                        .request_repaint_after(ERROR_BANNER_DURATION - elapsed);
                }
            }
        });
    }
}
