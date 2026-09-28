# svg_viewer

A simple, fast desktop SVG viewer written in [Odin](https://odin-lang.org).
Everything is in Odin: SVG parsing, CSS, text layout, the font loader and
the rasterizer live in the `svg` package, and the window and input use
Odin's bundled `vendor:raylib` bindings. There are no dependencies beyond the
Odin compiler.

## Features

- Pan and zoom with mouse drag/scroll or the keyboard, crisp at any zoom
  level
- Live reload: the file is watched on disk, and the view updates
  automatically when it changes, while preserving your current pan/zoom
- Configurable background color for viewing SVGs with transparency
- Fit-to-window on load and on resize (until you manually pan/zoom)

## Building

```sh
make            # builds ./svgview
make test       # runs the renderer, view and CLI tests
make install    # installs to ~/.local/bin (override with PREFIX=/usr/local)
make uninstall
```

If `odin` isn't on your `PATH`, pass it in: `make ODIN=/path/to/odin`.

## Usage

```sh
svgview <FILE> [OPTIONS]
```

### Options

- `-b, --background <BACKGROUND>`: background color behind transparent
  areas (e.g. `white`, `#222`, `#ff000080`)
- `--width <WIDTH>`: initial window width in pixels (default: `1024`)
- `--height <HEIGHT>`: initial window height in pixels (default: `768`)

### Example

```sh
svgview assets/sample.svg --background white
```

## Controls

- **Drag**: pan
- **Scroll**: zoom (centered on the cursor)
- **Arrow keys**: pan
- **`+`/`-`**: zoom
- **`R` / `0`**: reset view
- **`Q`**: quit

## Renderer

- Shapes, paths (including arcs), transforms, `<use>`/`<symbol>`, nested
  `<svg>` viewports with `preserveAspectRatio`, and SVGZ.
- Fill and stroke with solid colors and linear/radial gradients (focal
  point, `spreadMethod`, `href` inheritance), fill rules, opacity, joins,
  caps, miter limits and dashes.
- Group opacity and `clip-path`, both rendered through layers clamped to the
  visible area.
- Stylesheets with type/class/id selectors, plus `style` attributes.
- `<text>`/`<tspan>` with system fonts (TrueType and CFF outlines),
  `x`/`y`/`dx`/`dy`, `text-anchor`, and letter and word spacing.

The renderer computes exact analytic-area coverage in f64. It culls curves
outside the view while still tracking true arc length, so dashes stay in
phase, and it renders in parallel horizontal bands.

Not supported (the viewer prints a warning when a document uses them):
filters, masks, patterns, markers, `<image>`, `<textPath>`, and text
shaping/kerning. Live reload uses inotify, so it's Linux-only.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE) for details.
