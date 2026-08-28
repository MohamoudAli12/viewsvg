use std::path::PathBuf;

use clap::Parser;

use crate::svg::tiny_skia;

/// A simple SVG viewer.
#[derive(Parser, Debug)]
#[command(name = "svg_viewer", about = "A simple SVG viewer")]
pub struct Args {
    /// Path to the SVG file to view
    pub file: PathBuf,

    /// Background color behind transparent areas (e.g. "white", "#222", "#ff000080")
    #[arg(short = 'b', long = "background")]
    pub background: Option<String>,

    /// Initial window width in pixels
    #[arg(long, default_value_t = 1024)]
    pub width: u32,

    /// Initial window height in pixels
    #[arg(long, default_value_t = 768)]
    pub height: u32,
}

pub fn parse_background(s: &str) -> anyhow::Result<tiny_skia::Color> {
    let color = csscolorparser::parse(s)
        .map_err(|err| anyhow::anyhow!("invalid --background color {s:?}: {err}"))?;

    tiny_skia::Color::from_rgba(
        color.r.clamp(0.0, 1.0),
        color.g.clamp(0.0, 1.0),
        color.b.clamp(0.0, 1.0),
        color.a.clamp(0.0, 1.0),
    )
    .ok_or_else(|| anyhow::anyhow!("invalid --background color {s:?}"))
}
