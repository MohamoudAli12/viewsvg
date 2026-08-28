mod app;
mod cli;
mod svg;
mod view;
mod watcher;

use clap::Parser;

use app::SvgViewerApp;
use cli::Args;
use svg::SvgDocument;

fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    if !args.file.exists() {
        eprintln!("error: file not found: {}", args.file.display());
        std::process::exit(1);
    }

    let background = match &args.background {
        Some(s) => match cli::parse_background(s) {
            Ok(color) => Some(color),
            Err(err) => {
                eprintln!("error: {err:#}");
                std::process::exit(1);
            }
        },
        None => None,
    };

    // Built once and shared across every (re)load: scanning system font
    // directories is expensive, and the file watcher can trigger many
    // reloads over a session.
    let mut fontdb = svg::usvg::fontdb::Database::new();
    fontdb.load_system_fonts();
    let fontdb = std::sync::Arc::new(fontdb);

    let document = match SvgDocument::load(&args.file, fontdb.clone()) {
        Ok(doc) => doc,
        Err(err) => {
            eprintln!("error: {err:#}");
            std::process::exit(1);
        }
    };

    let path = args.file.clone();
    let window_title = format!("SVG Viewer — {}", path.display());

    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([args.width as f32, args.height as f32])
            .with_title(window_title),
        ..Default::default()
    };

    eframe::run_native(
        "svg_viewer",
        native_options,
        Box::new(move |cc| {
            let reload_rx = watcher::spawn_watcher(path.clone(), cc.egui_ctx.clone());
            Ok(Box::new(SvgViewerApp::new(
                path, document, background, reload_rx, fontdb,
            )))
        }),
    )
    .map_err(|err| anyhow::anyhow!("failed to run application: {err}"))?;

    Ok(())
}
