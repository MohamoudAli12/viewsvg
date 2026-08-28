use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};

/// Watches `path` for changes on a background thread and sends a `()` on the
/// returned channel (debounced) whenever it changes. Also pokes `ctx` so the
/// otherwise event-driven egui app wakes up and redraws even if idle.
///
/// The parent directory is watched rather than the file itself: many editors
/// save by writing a temp file and renaming it over the original, which can
/// invalidate a watch placed directly on the file's inode.
pub fn spawn_watcher(path: PathBuf, ctx: egui::Context) -> Receiver<()> {
    let (tx, rx) = channel::<()>();

    std::thread::spawn(move || {
        let (raw_tx, raw_rx) = channel::<notify::Result<Event>>();

        let mut watcher = match RecommendedWatcher::new(raw_tx, notify::Config::default()) {
            Ok(w) => w,
            Err(err) => {
                eprintln!("warning: failed to start file watcher: {err}");
                return;
            }
        };

        let watch_dir = path.parent().unwrap_or_else(|| Path::new("."));
        if let Err(err) = watcher.watch(watch_dir, RecursiveMode::NonRecursive) {
            eprintln!(
                "warning: failed to watch {} for changes: {err}",
                watch_dir.display()
            );
            return;
        }

        // `notify` reports absolute paths regardless of how `path` was spelled
        // on the command line, so compare against the canonicalized form.
        let canonical_target = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());

        let mut last_sent = Instant::now() - Duration::from_secs(1);
        for res in raw_rx {
            let Ok(event) = res else { continue };
            if !event.paths.iter().any(|p| p == &canonical_target) {
                continue;
            }

            let now = Instant::now();
            if now.duration_since(last_sent) < Duration::from_millis(150) {
                continue;
            }
            last_sent = now;

            if tx.send(()).is_err() {
                break; // app has shut down
            }
            ctx.request_repaint();
        }
    });

    rx
}
