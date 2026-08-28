/// Pan/zoom state for the viewer, in screen-pixel space.
///
/// `offset` is the screen-pixel position (relative to the canvas's top-left)
/// of the top-left corner of the rasterized image at the current `scale`.
#[derive(Clone, Copy, Debug)]
pub struct ViewState {
    pub scale: f32,
    pub offset: egui::Vec2,
    /// Once the user pans or zooms, stop auto-fitting on resize so their
    /// chosen view is preserved.
    pub user_adjusted: bool,
}

impl Default for ViewState {
    fn default() -> Self {
        Self {
            scale: 1.0,
            offset: egui::Vec2::ZERO,
            user_adjusted: false,
        }
    }
}

impl ViewState {
    /// Recomputes scale/offset to fit `svg_size` inside `avail_size`, centered.
    /// No-op once the user has manually panned or zoomed.
    pub fn refit(&mut self, svg_size: egui::Vec2, avail_size: egui::Vec2) {
        if self.user_adjusted {
            return;
        }
        self.scale = fit_scale(svg_size, avail_size);
        self.offset = (avail_size - svg_size * self.scale) / 2.0;
    }

    /// Zooms by `factor`, keeping the SVG-space point under `cursor_local`
    /// (canvas-local screen coordinates) visually fixed.
    pub fn zoom(&mut self, factor: f32, cursor_local: egui::Vec2, min_scale: f32, max_scale: f32) {
        let svg_point = (cursor_local - self.offset) / self.scale;
        let new_scale = (self.scale * factor).clamp(min_scale, max_scale);
        self.offset = cursor_local - svg_point * new_scale;
        self.scale = new_scale;
        self.user_adjusted = true;
    }

    pub fn pan(&mut self, delta: egui::Vec2) {
        self.offset += delta;
        self.user_adjusted = true;
    }
}

pub fn fit_scale(svg_size: egui::Vec2, avail_size: egui::Vec2) -> f32 {
    if svg_size.x <= 0.0 || svg_size.y <= 0.0 || avail_size.x <= 0.0 || avail_size.y <= 0.0 {
        return 1.0;
    }
    (avail_size.x / svg_size.x)
        .min(avail_size.y / svg_size.y)
        .max(0.001)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_scale_picks_the_limiting_dimension() {
        let scale = fit_scale(egui::vec2(200.0, 100.0), egui::vec2(100.0, 100.0));
        assert!((scale - 0.5).abs() < 1e-6);
    }

    #[test]
    fn fit_centers_the_image() {
        let mut view = ViewState::default();
        view.refit(egui::vec2(200.0, 100.0), egui::vec2(100.0, 100.0));
        assert!((view.scale - 0.5).abs() < 1e-6);
        assert!((view.offset - egui::vec2(0.0, 25.0)).length() < 1e-4);
    }

    #[test]
    fn zoom_keeps_cursor_point_fixed() {
        let mut view = ViewState {
            scale: 1.0,
            offset: egui::Vec2::ZERO,
            user_adjusted: false,
        };
        let cursor = egui::vec2(50.0, 30.0);
        let svg_point_before = (cursor - view.offset) / view.scale;

        view.zoom(2.0, cursor, 0.01, 100.0);

        let svg_point_after = (cursor - view.offset) / view.scale;
        assert!((svg_point_before - svg_point_after).length() < 1e-4);
        assert!(view.user_adjusted);
    }

    #[test]
    fn zoom_clamps_to_range() {
        let mut view = ViewState::default();
        view.zoom(1000.0, egui::Vec2::ZERO, 0.01, 100.0);
        assert!((view.scale - 100.0).abs() < 1e-4);

        view.zoom(0.0001, egui::Vec2::ZERO, 0.01, 100.0);
        assert!((view.scale - 0.01).abs() < 1e-4);
    }

    #[test]
    fn refit_is_noop_after_user_adjustment() {
        let mut view = ViewState::default();
        view.pan(egui::vec2(10.0, 10.0));
        let before = view;
        view.refit(egui::vec2(200.0, 100.0), egui::vec2(400.0, 400.0));
        assert_eq!(before.offset, view.offset);
        assert_eq!(before.scale, view.scale);
    }
}
