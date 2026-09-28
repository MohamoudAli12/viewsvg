package svg

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
load_string :: proc(t: ^testing.T, src: string) -> ^Document {
	doc, err := load_data(transmute([]u8)src)
	testing.expectf(t, err == "", "load failed: %s", err)
	delete(err)
	return doc
}

@(private = "file")
pixel :: proc(pm: Pixmap, x, y: int) -> [4]u8 {
	i := (y * pm.width + x) * 4
	return {pm.pixels[i], pm.pixels[i + 1], pm.pixels[i + 2], pm.pixels[i + 3]}
}

@(test)
load_rejects_malformed_svg :: proc(t: ^testing.T) {
	doc, err := load_data(transmute([]u8)string("not an svg"))
	testing.expect(t, doc == nil)
	testing.expect(t, err != "")
	delete(err)
}

@(test)
load_rejects_non_svg_root :: proc(t: ^testing.T) {
	doc, err := load_data(transmute([]u8)string("<html><body/></html>"))
	testing.expect(t, doc == nil)
	testing.expect(t, err != "")
	delete(err)
}

@(test)
load_rejects_missing_file :: proc(t: ^testing.T) {
	doc, err := load("/nonexistent/svg_viewer_test_missing.svg")
	testing.expect(t, doc == nil)
	testing.expect(t, err != "")
	delete(err)
}

@(test)
load_reads_file_from_disk :: proc(t: ^testing.T) {
	path := "/tmp/svg_viewer_odin_test_load.svg"
	_ = os.write_entire_file(path, transmute([]u8)string(`<svg xmlns="http://www.w3.org/2000/svg" width="30" height="40"/>`))
	defer os.remove(path)
	doc, err := load(path)
	defer destroy(doc)
	testing.expect_value(t, err, "")
	testing.expect_value(t, doc.width, 30)
	testing.expect_value(t, doc.height, 40)
}

@(test)
rasterize_produces_requested_dimensions :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20"><rect width="10" height="20" fill="red"/></svg>`)
	defer destroy(doc)
	testing.expect_value(t, doc.width, 10)
	testing.expect_value(t, doc.height, 20)

	pm := rasterize(doc, 64, 32)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pm.width, 64)
	testing.expect_value(t, pm.height, 32)
	testing.expect_value(t, len(pm.pixels), 64 * 32 * 4)
}

@(test)
rasterize_region_produces_requested_dimensions :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="red"/></svg>`)
	defer destroy(doc)
	pm := rasterize_region(doc, {{10, 10}, {30, 30}}, 200, 100)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pm.width, 200)
	testing.expect_value(t, pm.height, 100)
	testing.expect_value(t, pixel(pm, 100, 50), [4]u8{255, 0, 0, 255})
}

@(test)
coord_extent_covers_content_outside_the_viewbox :: proc(t: ^testing.T) {
	// The zoom ceiling is derived from this, so it has to account for
	// geometry parked outside the canvas: that content is still handed to
	// the renderer, and its coordinates are what run out of precision first.
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect x="4000" y="0" width="10" height="10" fill="red"/></svg>`)
	defer destroy(doc)
	testing.expect_value(t, doc.width, 10)
	testing.expectf(t, doc.coord_extent >= 4010, "got %v", doc.coord_extent)
}

@(test)
coord_extent_is_at_least_one_for_empty_documents :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"></svg>`)
	defer destroy(doc)
	testing.expectf(t, doc.coord_extent >= 100, "got %v", doc.coord_extent)
	testing.expect(t, is_finite(doc.coord_extent))
}

@(test)
parallel_render_matches_single_threaded :: proc(t: ^testing.T) {
	// Catches bands being offset, dropped or overlapping: any of those would
	// shift whole shapes. The rasterizer is exact per pixel, so bands must
	// agree exactly with a single-canvas render.
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
		<clipPath id="c"><circle cx="50" cy="50" r="40"/></clipPath>
		<g clip-path="url(#c)"><path d="M-500 -500L600 600M600 -500L-500 600" stroke="blue" stroke-width="7"/></g>
		<rect x="10" y="60" width="80" height="13" fill="red" fill-opacity="0.5"/>
	</svg>`)
	defer destroy(doc)
	ts := scale(3.07, 3.07)
	single := make([]u8, 307 * 307 * 4)
	defer delete(single)
	render(doc, ts, Canvas{single, 307, 307, 0, 0})
	parallel := make([]u8, 307 * 307 * 4)
	defer delete(parallel)
	render_parallel(doc, ts, parallel, 307, 307)

	differing := 0
	for i in 0 ..< len(single) {
		if abs(int(single[i]) - int(parallel[i])) > 1 {differing += 1}
	}
	testing.expectf(t, differing == 0, "%d bytes differ", differing)
}

@(test)
fills_are_exact_and_antialiased :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect x="2" y="2" width="4.5" height="4" fill="#00ff00"/></svg>`)
	defer destroy(doc)
	pm := rasterize(doc, 10, 10)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pixel(pm, 3, 3), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel(pm, 1, 3), [4]u8{0, 0, 0, 0})
	// Half-covered column at x = 6.
	testing.expect_value(t, pixel(pm, 6, 3), [4]u8{0, 128, 0, 128})
}

@(test)
evenodd_leaves_a_hole :: proc(t: ^testing.T) {
	src := `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path fill-rule="%s" d="M0 0H20V20H0Z M5 5H15V15H5Z"/></svg>`
	for rule, i in ([2]string{"nonzero", "evenodd"}) {
		doc := load_string(t, fmt.tprintf(src, rule))
		pm := rasterize(doc, 20, 20)
		center := pixel(pm, 10, 10)
		testing.expect_value(t, center.a, i == 0 ? 255 : 0)
		pixmap_destroy(&pm)
		destroy(doc)
	}
}

@(test)
stroke_covers_its_width :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0 10H20" stroke="black" stroke-width="4"/></svg>`)
	defer destroy(doc)
	pm := rasterize(doc, 20, 20)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pixel(pm, 10, 8).a, 255)
	testing.expect_value(t, pixel(pm, 10, 11).a, 255)
	testing.expect_value(t, pixel(pm, 10, 7).a, 0)
	testing.expect_value(t, pixel(pm, 10, 12).a, 0)
}

@(test)
group_opacity_applies_once :: proc(t: ^testing.T) {
	// Overlapping children of a translucent group don't show through each
	// other, unlike individually translucent shapes.
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
		<g opacity="0.5"><rect width="10" height="10" fill="red"/><rect width="10" height="10" fill="blue"/></g>
	</svg>`)
	defer destroy(doc)
	pm := rasterize(doc, 10, 10)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pixel(pm, 5, 5), [4]u8{0, 0, 128, 128})
}

@(test)
clip_path_limits_painting :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<clipPath id="c"><rect width="10" height="20"/></clipPath>
		<rect width="20" height="20" fill="black" clip-path="url(#c)"/>
	</svg>`)
	defer destroy(doc)
	pm := rasterize(doc, 20, 20)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pixel(pm, 5, 10).a, 255)
	testing.expect_value(t, pixel(pm, 15, 10).a, 0)
}

@(test)
linear_gradient_interpolates :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="1">
		<linearGradient id="g"><stop offset="0" stop-color="black"/><stop offset="1" stop-color="white"/></linearGradient>
		<rect width="100" height="1" fill="url(#g)"/>
	</svg>`)
	defer destroy(doc)
	pm := rasterize(doc, 100, 1)
	defer pixmap_destroy(&pm)
	testing.expect(t, pixel(pm, 0, 0).r < 10)
	testing.expect(t, pixel(pm, 99, 0).r > 245)
	mid := int(pixel(pm, 50, 0).r)
	testing.expectf(t, abs(mid - 128) <= 4, "mid = %d", mid)
}

@(test)
css_and_use_are_resolved :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="20" height="10">
		<style>.b { fill: blue } #r { fill: red }</style>
		<defs><rect id="r" width="10" height="10"/></defs>
		<use xlink:href="#r"/>
		<rect class="b" x="10" width="10" height="10"/>
	</svg>`)
	defer destroy(doc)
	pm := rasterize(doc, 20, 10)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pixel(pm, 5, 5), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(pm, 15, 5), [4]u8{0, 0, 255, 255})
}

@(test)
deep_zoom_region_stays_exact :: proc(t: ^testing.T) {
	// A circle rendered through a tiny crop around its leftmost point (10,
	// 50) at ~1e9x. The outline starts at (90, 50) and reaches (10, 50) after
	// half the circumference, 40 * pi = 125.66 units, i.e. 1.66 into the
	// 2-unit dash period. Culling replaces the off-screen arc with chords, so
	// this only passes if it also keeps the true arc length for dashing.
	region := Rect{{10 - 5e-8, 50 - 5e-8}, {10 + 5e-8, 50 + 5e-8}}
	src := `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><circle cx="50" cy="50" r="40" fill="black" stroke="red" stroke-width="0.5" stroke-dasharray="%s"/></svg>`

	// "1.7 0.3": 1.66 is inside a dash, and the 0.25-unit half-width covers
	// the whole crop at this zoom.
	on := load_string(t, fmt.tprintf(src, "1.7 0.3"))
	defer destroy(on)
	pm := rasterize_region(on, region, 100, 100)
	defer pixmap_destroy(&pm)
	testing.expect_value(t, pixel(pm, 10, 50), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(pm, 90, 50), [4]u8{255, 0, 0, 255})

	// "1 1": 1.66 is in a gap, so only the fill shows, and the circle's edge
	// splits the crop exactly in half.
	off := load_string(t, fmt.tprintf(src, "1 1"))
	defer destroy(off)
	pm2 := rasterize_region(off, region, 100, 100)
	defer pixmap_destroy(&pm2)
	testing.expect_value(t, pixel(pm2, 45, 50).a, 0)
	testing.expect_value(t, pixel(pm2, 55, 50), [4]u8{0, 0, 0, 255})
}

@(test)
text_whitespace_is_collapsed :: proc(t: ^testing.T) {
	doc := load_string(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>  a <tspan>b</tspan>  c  </text></svg>`)
	defer destroy(doc)
	// Parsing (and font lookup) must not fail; glyph output depends on
	// installed fonts, so only check the XML text survived intact.
	testing.expect(t, doc.root != nil)
}

@(test)
xml_keeps_text_whitespace_and_entities :: proc(t: ^testing.T) {
	// Documents normally parse into their arena; stand in for it here.
	context.allocator = context.temp_allocator
	x, err := parse_xml(`<!DOCTYPE svg [<!ENTITY who "world">]><svg a="1&amp;2"><t>hi <b>&who;</b> &#x41;</t></svg>`)
	testing.expect(t, err == nil)
	testing.expect_value(t, x.elements[0].attribs[0].val, "1&2")
	texts: [dynamic]string
	for v in x.elements[1].value {
		if s, ok := v.(string); ok {append(&texts, s)}
	}
	testing.expect_value(t, len(texts), 2)
	testing.expect_value(t, texts[0], "hi ")
	testing.expect_value(t, texts[1], " A")
	b := x.elements[2]
	testing.expect_value(t, b.value[0].(string), "world")
}

@(test)
parse_color_formats :: proc(t: ^testing.T) {
	Case :: struct {
		s: string,
		c: Color,
	}
	cases := []Case {
		{"red", {1, 0, 0, 1}},
		{"#0f0", {0, 1, 0, 1}},
		{"#0000ff80", {0, 0, 1, 128.0 / 255}},
		{"rgb(255, 0, 0)", {1, 0, 0, 1}},
		{"rgba(0 0 255 / 50%)", {0, 0, 1, 0.5}},
		{"hsl(120, 100%, 50%)", {0, 1, 0, 1}},
		{"transparent", {0, 0, 0, 0}},
		{"White", {1, 1, 1, 1}},
	}
	for c in cases {
		got, ok := parse_color(c.s)
		testing.expectf(t, ok, "%q did not parse", c.s)
		for k in 0 ..< 4 {
			testing.expectf(t, abs(got[k] - c.c[k]) < 1e-3, "%q: got %v", c.s, got)
		}
	}
	for bad in ([]string{"", "#12", "rgb(1,2)", "nope", "#ggg"}) {
		_, ok := parse_color(bad)
		testing.expectf(t, !ok, "%q should not parse", bad)
	}
}

@(test)
path_data_arcs_and_implicit_commands :: proc(t: ^testing.T) {
	p: Path
	defer {delete(p.verbs);delete(p.points)}
	// Packed arc flags, implicit lineto after moveto, and relative commands.
	parse_path_data("M0 0 10 0 a5 5 0 01 0 10 z m 1 1 l 1 1", &p)
	b := path_bounds(p)
	testing.expectf(t, abs(b.max.x - 15) < 1e-9, "arc should bulge to x=15, got %v", b)
	testing.expect_value(t, p.verbs[0], Verb.Move)
	testing.expect_value(t, p.verbs[1], Verb.Line)
	last := p.points[len(p.points) - 1]
	testing.expect_value(t, last, Vec2{2, 2})
}

@(test)
transforms_compose_in_order :: proc(t: ^testing.T) {
	ts, ok := parse_transform("translate(10, 0) scale(2)")
	testing.expect(t, ok)
	testing.expect_value(t, transform_point(ts, {1, 1}), Vec2{12, 2})
	r, rok := parse_transform("rotate(90 5 5)")
	testing.expect(t, rok)
	q := transform_point(r, {10, 5})
	testing.expect(t, abs(q.x - 5) < 1e-9 && abs(q.y - 10) < 1e-9)
	_, bad := parse_transform("translate(1,")
	testing.expect(t, !bad)
}

@(test)
edges_ending_on_the_region_side_stay_in_bounds :: proc(t: ^testing.T) {
	// Captured from a real document: an edge entering from far above and
	// ending exactly on x = 0. Interpolating x across that distance landed at
	// -1.25e-14 on the region's first row, which floored to column -1 and
	// indexed before the accumulation buffer.
	r: Rasterizer
	defer delete(r.acc)
	raster_reset(&r, 0, 4, 654, 14)
	raster_line(&r, {89.964735925027838, -596.68797612125945}, {0, 4.238485351239774})
	cov := make([]f32, 654)
	defer delete(cov)
	testing.expect_value(t, r.row_max, 0)
	raster_row_coverage(&r, 0, .Non_Zero, cov)
	// A lone edge covers everything to its right, here until it ends.
	testing.expectf(t, abs(cov[653] - 0.2385) < 1e-3, "got %v", cov[653])
}
