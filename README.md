# svg_viewer

A simple, fast desktop SVG viewer written in Rust. It renders SVGs with
[resvg](https://github.com/RazrFalcon/resvg) and displays them in a native
window built with [egui](https://github.com/emilk/egui)/[eframe](https://github.com/emilk/egui).

## Features

- Pan and zoom with mouse drag/scroll or the keyboard
- Live reload: the file is watched on disk, and the view updates automatically
  when it changes, while preserving your current pan/zoom
- Configurable background color for viewing SVGs with transparency
- Fit-to-window on load and on resize (until you manually pan/zoom)

## Installation

Requires a Rust toolchain (see [rustup.rs](https://rustup.rs)).

```sh
cargo build --release
```

The resulting binary is at `target/release/viewsvg`.

## Usage

```sh
viewsvg <FILE> [OPTIONS]
```

### Arguments

- `<FILE>` — path to the SVG file to view

### Options

- `-b, --background <BACKGROUND>` — background color behind transparent areas
  (e.g. `white`, `#222`, `#ff000080`)
- `--width <WIDTH>` — initial window width in pixels (default: `1024`)
- `--height <HEIGHT>` — initial window height in pixels (default: `768`)

### Example

```sh
viewsvg assets/sample.svg --background white
```

## Controls

- **Drag** — pan
- **Scroll** — zoom (centered on the cursor)
- **Arrow keys** — pan
- **`+`/`-`** — zoom
- **`R` / `0`** — reset view

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE) for details.
