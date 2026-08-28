pub use resvg::{tiny_skia, usvg};

use std::path::Path;
use std::sync::Arc;

use anyhow::Context;

pub struct SvgDocument {
    tree: usvg::Tree,
}

impl SvgDocument {
    /// Loads and parses the SVG at `path`, using `fontdb` for font matching.
    ///
    /// `fontdb` is expected to already have system fonts loaded; scanning
    /// system font directories is expensive, so callers should build it once
    /// (e.g. in `main`) and reuse it across reloads rather than rebuilding it
    /// per call.
    pub fn load(path: &Path, fontdb: Arc<usvg::fontdb::Database>) -> anyhow::Result<Self> {
        let data = std::fs::read(path)
            .with_context(|| format!("failed to read SVG file: {}", path.display()))?;

        let opt = usvg::Options {
            resources_dir: path.parent().map(|p| p.to_path_buf()),
            fontdb,
            ..Default::default()
        };

        let tree = usvg::Tree::from_data(&data, &opt)
            .with_context(|| format!("invalid SVG: {}", path.display()))?;

        Ok(Self { tree })
    }

    /// Natural document size in SVG user units.
    pub fn size(&self) -> (f32, f32) {
        let size = self.tree.size();
        (size.width(), size.height())
    }

    /// Rasterizes the whole document into a pixmap of exactly `px_width` x `px_height` pixels.
    pub fn rasterize(
        &self,
        px_width: u32,
        px_height: u32,
        background: Option<tiny_skia::Color>,
    ) -> tiny_skia::Pixmap {
        let (svg_w, svg_h) = self.size();
        let px_width = px_width.max(1);
        let px_height = px_height.max(1);

        let mut pixmap =
            tiny_skia::Pixmap::new(px_width, px_height).expect("pixmap dimensions are non-zero");
        if let Some(color) = background {
            pixmap.fill(color);
        }

        let sx = px_width as f32 / svg_w.max(1.0);
        let sy = px_height as f32 / svg_h.max(1.0);
        let transform = tiny_skia::Transform::from_scale(sx, sy);

        resvg::render(&self.tree, transform, &mut pixmap.as_mut());

        pixmap
    }

    /// Rasterizes only `svg_rect` (a sub-region in SVG user-space units) into
    /// a pixmap of exactly `px_width` x `px_height` pixels.
    ///
    /// Used when the whole document would need a texture larger than the
    /// rasterization cap to stay crisp at the current zoom: rather than
    /// downsampling the entire document into a capped-size pixmap (which
    /// looks blurry), only the visible crop is rendered, at full resolution.
    pub fn rasterize_region(
        &self,
        svg_rect: tiny_skia::Rect,
        px_width: u32,
        px_height: u32,
        background: Option<tiny_skia::Color>,
    ) -> tiny_skia::Pixmap {
        let px_width = px_width.max(1);
        let px_height = px_height.max(1);

        let mut pixmap =
            tiny_skia::Pixmap::new(px_width, px_height).expect("pixmap dimensions are non-zero");
        if let Some(color) = background {
            pixmap.fill(color);
        }

        let sx = px_width as f32 / svg_rect.width().max(1e-6);
        let sy = px_height as f32 / svg_rect.height().max(1e-6);
        let transform =
            tiny_skia::Transform::from_translate(-svg_rect.x(), -svg_rect.y()).post_scale(sx, sy);

        resvg::render(&self.tree, transform, &mut pixmap.as_mut());

        pixmap
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_fontdb() -> Arc<usvg::fontdb::Database> {
        Arc::new(usvg::fontdb::Database::new())
    }

    #[test]
    fn load_rejects_malformed_svg() {
        let dir = std::env::temp_dir();
        let path = dir.join("svg_viewer_test_malformed.svg");
        std::fs::write(&path, b"not an svg").unwrap();

        let result = SvgDocument::load(&path, empty_fontdb());

        std::fs::remove_file(&path).ok();
        assert!(result.is_err());
    }

    #[test]
    fn load_rejects_missing_file() {
        let path = Path::new("/nonexistent/svg_viewer_test_missing.svg");
        assert!(SvgDocument::load(path, empty_fontdb()).is_err());
    }

    #[test]
    fn rasterize_produces_requested_dimensions() {
        let dir = std::env::temp_dir();
        let path = dir.join("svg_viewer_test_rasterize.svg");
        std::fs::write(
            &path,
            br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20"><rect width="10" height="20" fill="red"/></svg>"#,
        )
        .unwrap();

        let doc = SvgDocument::load(&path, empty_fontdb()).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(doc.size(), (10.0, 20.0));

        let pixmap = doc.rasterize(64, 32, None);
        assert_eq!(pixmap.width(), 64);
        assert_eq!(pixmap.height(), 32);
    }

    #[test]
    fn rasterize_region_produces_requested_dimensions() {
        let dir = std::env::temp_dir();
        let path = dir.join("svg_viewer_test_rasterize_region.svg");
        std::fs::write(
            &path,
            br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="red"/></svg>"#,
        )
        .unwrap();

        let doc = SvgDocument::load(&path, empty_fontdb()).unwrap();
        std::fs::remove_file(&path).ok();

        let rect = tiny_skia::Rect::from_xywh(10.0, 10.0, 20.0, 20.0).unwrap();
        let pixmap = doc.rasterize_region(rect, 200, 100, None);
        assert_eq!(pixmap.width(), 200);
        assert_eq!(pixmap.height(), 100);
    }
}
