package main

import svg "svg"

Vec2 :: svg.Vec2

// Pan/zoom state for the viewer, in screen-point space.
//
// `offset` is the screen position (relative to the canvas's top-left) of the
// SVG origin at the current `scale`.
//
// Kept in f64: `offset` grows roughly in proportion to `scale`, and f32
// doesn't have enough significant digits to place it accurately once zoom
// gets deep, long before the renderer's own precision limit is reached.
View_State :: struct {
	scale:         f64,
	offset:        Vec2,
	// Once the user pans or zooms, stop auto-fitting on resize so their
	// chosen view is preserved.
	user_adjusted: bool,
}

DEFAULT_VIEW :: View_State {
	scale = 1,
}

// Recomputes scale/offset to fit `svg_size` inside `avail_size`, centered.
// No-op once the user has manually panned or zoomed.
view_refit :: proc(v: ^View_State, svg_size, avail_size: Vec2) {
	if v.user_adjusted {return}
	v.scale = fit_scale(svg_size, avail_size)
	v.offset = (avail_size - svg_size * v.scale) / 2
}

// Zooms by `factor`, keeping the SVG-space point under `cursor` (canvas-local
// screen coordinates) visually fixed.
view_zoom :: proc(v: ^View_State, factor: f64, cursor: Vec2, min_scale, max_scale: f64) {
	svg_point := (cursor - v.offset) / v.scale
	new_scale := clamp(v.scale * factor, min_scale, max_scale)
	v.offset = cursor - svg_point * new_scale
	v.scale = new_scale
	v.user_adjusted = true
}

view_pan :: proc(v: ^View_State, delta: Vec2) {
	v.offset += delta
	v.user_adjusted = true
}

fit_scale :: proc(svg_size, avail_size: Vec2) -> f64 {
	if svg_size.x <= 0 || svg_size.y <= 0 || avail_size.x <= 0 || avail_size.y <= 0 {
		return 1
	}
	return max(min(avail_size.x / svg_size.x, avail_size.y / svg_size.y), 0.001)
}

// Largest render scale (screen pixels per SVG user unit) that the renderer
// can still rasterize exactly, for a document whose geometry reaches
// `coord_extent` user units from the origin.
//
// The renderer transforms geometry to device space before rasterizing, so a
// coordinate at `coord_extent` drawn at scale `s` becomes a device
// coordinate of magnitude `s * coord_extent`, positioned with whatever of
// f64's mantissa that product leaves. `budget` caps the product.
//
// Capping the product rather than the scale is what lets zoom depth adapt to
// the document: an icon with 24-unit coordinates gets a far higher scale
// ceiling than a 10000-unit map, and both stay crisp all the way to it.
// Never returns less than `min_scale`, so the range handed to `view_zoom` is
// always well-formed.
max_scale_for_extent :: proc(coord_extent, budget, min_scale: f64) -> f64 {
	if !svg.is_finite(coord_extent) || coord_extent <= 0 {
		return max(budget, min_scale)
	}
	return max(budget / coord_extent, min_scale)
}
