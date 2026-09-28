package main

import "core:math"
import "core:testing"

@(test)
fit_scale_picks_the_limiting_dimension :: proc(t: ^testing.T) {
	testing.expect(t, abs(fit_scale({200, 100}, {100, 100}) - 0.5) < 1e-6)
}

@(test)
fit_centers_the_image :: proc(t: ^testing.T) {
	v := DEFAULT_VIEW
	view_refit(&v, {200, 100}, {100, 100})
	testing.expect(t, abs(v.scale - 0.5) < 1e-6)
	testing.expect(t, abs(v.offset.x) < 1e-4)
	testing.expect(t, abs(v.offset.y - 25) < 1e-4)
}

@(test)
zoom_keeps_cursor_point_fixed :: proc(t: ^testing.T) {
	v := DEFAULT_VIEW
	cursor := Vec2{50, 30}
	before := (cursor - v.offset) / v.scale
	view_zoom(&v, 2, cursor, 0.01, 100)
	after := (cursor - v.offset) / v.scale
	d := before - after
	testing.expect(t, math.sqrt(d.x * d.x + d.y * d.y) < 1e-4)
	testing.expect(t, v.user_adjusted)
}

@(test)
zoom_clamps_to_range :: proc(t: ^testing.T) {
	v := DEFAULT_VIEW
	view_zoom(&v, 1000, {}, 0.01, 100)
	testing.expect(t, abs(v.scale - 100) < 1e-4)
	view_zoom(&v, 0.0001, {}, 0.01, 100)
	testing.expect(t, abs(v.scale - 0.01) < 1e-4)
}

@(test)
max_scale_adapts_to_document_coordinate_extent :: proc(t: ^testing.T) {
	// The same precision budget has to buy far more zoom on a small-
	// coordinate document than on a large one; that ratio is the whole
	// point of capping the product instead of the scale.
	budget: f64 = 1e7
	icon := max_scale_for_extent(24, budget, 0.01)
	page := max_scale_for_extent(1000, budget, 0.01)
	testing.expect(t, abs(icon * 24 - budget) < 1)
	testing.expect(t, abs(page * 1000 - budget) < 1)
	testing.expect(t, icon > page * 40)
}

@(test)
max_scale_stays_usable_for_degenerate_extents :: proc(t: ^testing.T) {
	// A zero/NaN extent must not collapse the zoom range or produce a max
	// below min, which would make `view_zoom`'s clamp ill-formed.
	for extent in ([]f64{0, -5, math.nan_f64(), math.inf_f64(1)}) {
		m := max_scale_for_extent(extent, 1e7, 0.01)
		testing.expectf(t, m >= 0.01, "extent %v gave max %v", extent, m)
	}
	// Coordinates so large the budget alone would fall under `min_scale`.
	testing.expect_value(t, max_scale_for_extent(1e12, 1e7, 0.01), 0.01)
}

@(test)
zoom_stays_accurate_near_max_scale :: proc(t: ^testing.T) {
	// As scale grows, offset grows roughly proportionally; f64 has to keep
	// the cursor-anchored point and the derived viewport rect accurate
	// across the whole zoom range, which for a small-coordinate document
	// runs to 1e10 here.
	max_scale := max_scale_for_extent(10, MAX_COORD_MAGNITUDE, 0.01)
	testing.expect_value(t, max_scale, 1e10)
	v := DEFAULT_VIEW
	cursor := Vec2{400, 300}
	for _ in 0 ..< 60 {
		view_zoom(&v, 2, cursor, 0.01, max_scale)
	}
	testing.expect_value(t, v.scale, max_scale)
	p := (cursor - v.offset) / v.scale
	testing.expect(t, abs(p.x - 400) < 1e-6 && abs(p.y - 300) < 1e-6)

	// Mirrors app.odin's viewport-in-SVG-space computation for the crop
	// path; must stay positive and finite.
	lo := -v.offset / v.scale
	size := Vec2{800, 600} / v.scale
	testing.expect(t, size.x > 0 && size.y > 0 && lo.x == lo.x)
}

@(test)
refit_is_noop_after_user_adjustment :: proc(t: ^testing.T) {
	v := DEFAULT_VIEW
	view_pan(&v, {10, 10})
	before := v
	view_refit(&v, {200, 100}, {400, 400})
	testing.expect_value(t, v.offset, before.offset)
	testing.expect_value(t, v.scale, before.scale)
}

@(test)
cli_parses_options :: proc(t: ^testing.T) {
	args, err, help := parse_args({"file.svg", "-b", "#ff000080", "--width=640", "--height", "480"})
	testing.expect_value(t, err, "")
	testing.expect(t, !help)
	testing.expect_value(t, args.file, "file.svg")
	testing.expect_value(t, args.width, 640)
	testing.expect_value(t, args.height, 480)
	bg, ok := args.background.?
	testing.expect(t, ok && bg.r == 1 && abs(bg.a - 128.0 / 255) < 1e-6)
}

@(test)
cli_rejects_bad_input :: proc(t: ^testing.T) {
	for argv in ([][]string{{}, {"a.svg", "--background", "nope"}, {"a.svg", "--width", "0"}, {"a.svg", "b.svg"}, {"a.svg", "--frobnicate"}}) {
		_, err, _ := parse_args(argv)
		testing.expectf(t, err != "", "%v should fail", argv)
	}
	_, _, help := parse_args({"--help"})
	testing.expect(t, help)
}
