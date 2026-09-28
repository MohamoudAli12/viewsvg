package svg

import "base:runtime"
import "core:math"
import "core:os"
import "core:thread"

// Premultiplied RGBA8 pixels covering the device-space rectangle
// (x, y, width, height). Rendering never touches anything outside it.
Canvas :: struct {
	pixels:        []u8,
	width, height: int,
	x, y:          int,
}

// An owned premultiplied RGBA8 image.
Pixmap :: struct {
	pixels:        []u8,
	width, height: int,
}

pixmap_destroy :: proc(p: ^Pixmap) {
	delete(p.pixels)
	p^ = {}
}

// Rasterizes the whole document into exactly `px_width` x `px_height` pixels.
rasterize :: proc(doc: ^Document, px_width, px_height: int, background: Maybe(Color) = nil) -> Pixmap {
	w, h := max(px_width, 1), max(px_height, 1)
	return rasterize_with(doc, scale(f64(w) / max(doc.width, 1), f64(h) / max(doc.height, 1)), w, h, background)
}

// Rasterizes only `region` (in SVG user units, i.e. the root viewport's
// coordinates) into exactly `px_width` x `px_height` pixels. Used when
// zoomed in too far for a whole-document raster to stay sharp.
rasterize_region :: proc(doc: ^Document, region: Rect, px_width, px_height: int, background: Maybe(Color) = nil) -> Pixmap {
	w, h := max(px_width, 1), max(px_height, 1)
	sx := f64(w) / max(region.max.x - region.min.x, 1e-300)
	sy := f64(h) / max(region.max.y - region.min.y, 1e-300)
	return rasterize_with(doc, Transform{sx, 0, 0, sy, -region.min.x * sx, -region.min.y * sy}, w, h, background)
}

@(private = "file")
rasterize_with :: proc(doc: ^Document, ts: Transform, w, h: int, background: Maybe(Color)) -> Pixmap {
	pm := Pixmap{make([]u8, w * h * 4), w, h}
	if bg, has := background.?; has {
		px := [4]u8{
			u8(math.round(bg.r * bg.a * 255)),
			u8(math.round(bg.g * bg.a * 255)),
			u8(math.round(bg.b * bg.a * 255)),
			u8(math.round(bg.a * 255)),
		}
		for i := 0; i < len(pm.pixels); i += 4 {
			(^[4]u8)(&pm.pixels[i])^ = px
		}
	}
	render_parallel(doc, ts, pm.pixels, w, h)
	return pm
}

// Renders `doc` through `ts` onto the `width` x `height` pixels using every
// core. The image is split into horizontal bands, each rendered as its own
// small canvas; there are more bands than threads, dealt out round-robin, so
// a thread that lands on a busy part of the document doesn't get all of it.
render_parallel :: proc(doc: ^Document, ts: Transform, pixels: []u8, width, height: int) {
	threads := min(os.get_processor_core_count(), height)
	if threads <= 1 {
		render(doc, ts, Canvas{pixels, width, height, 0, 0})
		return
	}

	Job :: struct {
		doc:                      ^Document,
		ts:                       Transform,
		pixels:                   []u8,
		width, height:            int,
		band_height, band_count:  int,
		first, step:              int,
	}
	band_count := min(threads * 4, height)
	band_height := (height + band_count - 1) / band_count
	band_count = (height + band_height - 1) / band_height

	jobs := make([]Job, threads)
	defer delete(jobs)
	workers := make([]^thread.Thread, threads)
	defer delete(workers)
	for i in 0 ..< threads {
		jobs[i] = Job{doc, ts, pixels, width, height, band_height, band_count, i, threads}
		workers[i] = thread.create_and_start_with_poly_data(&jobs[i], proc(job: ^Job) {
			for band := job.first; band < job.band_count; band += job.step {
				y := band * job.band_height
				rows := min(job.band_height, job.height - y)
				canvas := Canvas{job.pixels[y * job.width * 4:][:rows * job.width * 4], job.width, rows, 0, y}
				render(job.doc, job.ts, canvas)
			}
		})
	}
	for t in workers {
		thread.join(t)
		thread.destroy(t)
	}
}

// Renders `doc` mapped through `ts` onto `canvas`, compositing over what is
// already there.
render :: proc(doc: ^Document, ts: Transform, canvas: Canvas) {
	ctx: Render_Ctx
	defer {
		delete(ctx.r.acc)
		delete(ctx.cov)
	}
	render_group(&ctx, doc.root, ts, canvas)
}

@(private = "file")
Render_Ctx :: struct {
	r:   Rasterizer,
	cov: [dynamic]f32,
}

@(private = "file")
render_node :: proc(ctx: ^Render_Ctx, node: Node, ctm: Transform, canvas: Canvas) {
	switch n in node {
	case ^Group:
		render_group(ctx, n, ctm, canvas)
	case ^Shape:
		render_shape(ctx, n, ctm, canvas)
	}
}

// Device-pixel rect covering `r` (device space) and inside `canvas`.
@(private = "file")
pixel_bounds :: proc(r: Rect, canvas: Canvas) -> (x0, y0, x1, y1: int, ok: bool) {
	if rect_is_empty(r) {return}
	cx0, cy0 := f64(canvas.x), f64(canvas.y)
	cx1, cy1 := cx0 + f64(canvas.width), cy0 + f64(canvas.height)
	// Clamp in f64 first: bounds at deep zoom are far outside int range.
	x0 = int(clamp(math.floor(r.min.x) - 1, cx0, cx1))
	y0 = int(clamp(math.floor(r.min.y) - 1, cy0, cy1))
	x1 = int(clamp(math.ceil(r.max.x) + 1, cx0, cx1))
	y1 = int(clamp(math.ceil(r.max.y) + 1, cy0, cy1))
	return x0, y0, x1, y1, x1 > x0 && y1 > y0
}

@(private = "file")
render_group :: proc(ctx: ^Render_Ctx, g: ^Group, ctm: Transform, canvas: Canvas) {
	m := transform_mul(ctm, g.transform)
	if g.opacity >= 1 && g.clip == nil {
		for c in g.children {
			render_node(ctx, c, m, canvas)
		}
		return
	}
	if g.opacity <= 0 {return}

	// Opacity and clipping apply to the group as a whole, so it's rendered
	// into a layer first. The layer only spans the group's bounds within the
	// canvas: pixels outside the canvas can never be seen.
	x0, y0, x1, y1, visible := pixel_bounds(rect_transform(m, g.bounds), canvas)
	if !visible {return}
	layer := Canvas{make([]u8, (x1 - x0) * (y1 - y0) * 4), x1 - x0, y1 - y0, x0, y0}
	defer delete(layer.pixels)

	for c in g.children {
		render_node(ctx, c, m, layer)
	}
	if g.clip != nil {
		mask := make([]f32, layer.width * layer.height)
		defer delete(mask)
		clip_mask(ctx, g.clip, m, g.bbox, layer, mask)
		for v, i in mask {
			px := layer.pixels[i * 4:][:4]
			for k in 0 ..< 4 {
				px[k] = u8(f32(px[k]) * v + 0.5)
			}
		}
	}

	opacity := g.opacity
	for row in 0 ..< layer.height {
		src := layer.pixels[row * layer.width * 4:][:layer.width * 4]
		dst := canvas.pixels[((y0 - canvas.y + row) * canvas.width + (x0 - canvas.x)) * 4:][:layer.width * 4]
		for i := 0; i < len(src); i += 4 {
			if src[i + 3] == 0 {continue}
			blend(dst[i:][:4], {f32(src[i]), f32(src[i + 1]), f32(src[i + 2]), f32(src[i + 3])} * opacity)
		}
	}
}

// Writes the coverage of `clip` over `layer` into `mask` (zeroed by caller).
@(private = "file")
clip_mask :: proc(ctx: ^Render_Ctx, clip: ^Clip_Path, m: Transform, bbox: Rect, layer: Canvas, mask: []f32) {
	cm := transform_mul(m, clip.transform)
	if clip.object_bbox_units {
		w, h := bbox.max.x - bbox.min.x, bbox.max.y - bbox.min.y
		if !(w > 0 && h > 0) {return}
		cm = transform_mul(cm, Transform{w, 0, 0, h, bbox.min.x, bbox.min.y})
	}
	resize(&ctx.cov, layer.width)
	for item in clip.items {
		im := transform_mul(cm, item.transform)
		x0, y0, x1, y1 := pixel_bounds(path_control_bounds(item.path, im), layer) or_continue
		fill_coverage(ctx, item.path, im, x0, y0, x1, y1)
		for row in ctx.r.row_min ..= ctx.r.row_max {
			cov := ctx.cov[:ctx.r.w]
			raster_row_coverage(&ctx.r, row, item.rule, cov)
			line := mask[(y0 - layer.y + row) * layer.width + (x0 - layer.x):][:ctx.r.w]
			for c, i in cov {
				line[i] += c - line[i] * c
			}
		}
	}
	if clip.clip != nil {
		inner := make([]f32, len(mask))
		defer delete(inner)
		clip_mask(ctx, clip.clip, m, bbox, layer, inner)
		for &v, i in mask {
			v *= inner[i]
		}
	}
}

// Accumulates `path` under `m` into the rasterizer over the given device
// rect; coverage is then read row by row with `raster_row_coverage`.
@(private = "file")
fill_coverage :: proc(ctx: ^Render_Ctx, path: Path, m: Transform, x0, y0, x1, y1: int) {
	raster_reset(&ctx.r, x0, y0, x1 - x0, y1 - y0)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	polylines := make([dynamic]Polyline, context.temp_allocator)
	cull := Rect{{f64(x0) - 1, f64(y0) - 1}, {f64(x1) + 1, f64(y1) + 1}}
	flatten_path(path, m, FLATTEN_TOLERANCE, cull, &polylines)
	for pl in polylines {
		n := len(pl.pts)
		for i in 0 ..< n {
			// Fills implicitly close every subpath.
			raster_line(&ctx.r, pl.pts[i], pl.pts[(i + 1) % n])
		}
	}
}

@(private = "file")
render_shape :: proc(ctx: ^Render_Ctx, s: ^Shape, ctm: Transform, canvas: Canvas) {
	m := transform_mul(ctm, s.transform)
	if fill, has := s.fill.?; has {
		if x0, y0, x1, y1, ok := pixel_bounds(path_control_bounds(s.path, m), canvas); ok {
			fill_coverage(ctx, s.path, m, x0, y0, x1, y1)
			paint_coverage(ctx, canvas, fill.rule, fill.paint, fill.opacity, m, s.bbox)
		}
	}
	if stroke, has := s.stroke.?; has {
		if x0, y0, x1, y1, ok := pixel_bounds(rect_transform(m, s.bounds), canvas); ok {
			raster_reset(&ctx.r, x0, y0, x1 - x0, y1 - y0)
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			stroke_path(&ctx.r, s.path, m, stroke)
			paint_coverage(ctx, canvas, .Non_Zero, stroke.paint, stroke.opacity, m, s.bbox)
		}
	}
}

// Composites the rasterizer's accumulated coverage onto `canvas` with `paint`.
@(private = "file")
paint_coverage :: proc(ctx: ^Render_Ctx, canvas: Canvas, rule: Fill_Rule, paint: Paint, opacity: f32, m: Transform, bbox: Rect) {
	r := &ctx.r
	pc, ok := prepare_paint(paint, opacity, m, bbox)
	if !ok {
		// Still have to clear what was accumulated.
		resize(&ctx.cov, r.w)
		for row in r.row_min ..= r.row_max {
			raster_row_coverage(r, row, rule, ctx.cov[:r.w])
		}
		return
	}
	resize(&ctx.cov, r.w)
	cov := ctx.cov[:r.w]
	for row in r.row_min ..= r.row_max {
		raster_row_coverage(r, row, rule, cov)
		dst := canvas.pixels[((r.y - canvas.y + row) * canvas.width + (r.x - canvas.x)) * 4:][:r.w * 4]
		y := f64(r.y + row) + 0.5
		for c, i in cov {
			if c <= 0 {continue}
			color := pc.solid
			if pc.gradient != nil {
				color = paint_at(&pc, {f64(r.x + i) + 0.5, y})
			}
			blend(dst[i * 4:][:4], color * (c * 255))
		}
	}
}

// src-over of a premultiplied color given in 0..255 units.
@(private = "file")
blend :: #force_inline proc(dst: []u8, src: [4]f32) {
	inv := 1 - src.a / 255
	for k in 0 ..< 4 {
		dst[k] = u8(clamp(src[k] + f32(dst[k]) * inv + 0.5, 0, 255))
	}
}

@(private = "file")
GRADIENT_LUT_SIZE :: 256

@(private = "file")
Paint_Ctx :: struct {
	solid:    [4]f32, // premultiplied, 0..1
	gradient: ^Gradient,
	inv:      Transform, // device -> gradient space
	lut:      [GRADIENT_LUT_SIZE][4]f32, // premultiplied, 0..1
}

@(private = "file")
prepare_paint :: proc(paint: Paint, opacity: f32, m: Transform, bbox: Rect) -> (pc: Paint_Ctx, ok: bool) {
	premul :: proc(c: Color, opacity: f32) -> [4]f32 {
		a := c.a * opacity
		return {c.r * a, c.g * a, c.b * a, a}
	}
	switch paint.kind {
	case .Solid:
		pc.solid = premul(paint.color, opacity)
		return pc, pc.solid.a > 0
	case .Gradient:
		g := paint.gradient
		fwd := m
		if g.object_bbox_units {
			fwd = transform_mul(fwd, Transform{bbox.max.x - bbox.min.x, 0, 0, bbox.max.y - bbox.min.y, bbox.min.x, bbox.min.y})
		}
		fwd = transform_mul(fwd, g.transform)
		pc.inv = transform_invert(fwd) or_return
		pc.gradient = g
		stops := g.stops
		j := 0
		for i in 0 ..< GRADIENT_LUT_SIZE {
			t := f32(i) / (GRADIENT_LUT_SIZE - 1)
			for j < len(stops) - 1 && stops[j + 1].offset < t {j += 1}
			c: Color
			switch {
			case t <= stops[0].offset:
				c = stops[0].color
			case j >= len(stops) - 1:
				c = stops[len(stops) - 1].color
			case:
				a, b := stops[j], stops[j + 1]
				span := b.offset - a.offset
				f := span > 0 ? (t - a.offset) / span : 1
				c = a.color + (b.color - a.color) * f
			}
			pc.lut[i] = premul(c, opacity)
		}
		return pc, true
	}
	return
}

@(private = "file")
paint_at :: proc(pc: ^Paint_Ctx, p: Vec2) -> [4]f32 {
	g := pc.gradient
	q := transform_point(pc.inv, p)
	t: f64
	if g.radial {
		// Find t such that q lies on the circle centered at
		// focal + t * (center - focal) with radius t * radius.
		cd := g.center - g.focal
		pd := q - g.focal
		a := cd.x * cd.x + cd.y * cd.y - g.radius * g.radius // < 0: focal is inside
		b := pd.x * cd.x + pd.y * cd.y
		c := pd.x * pd.x + pd.y * pd.y
		t = (b - math.sqrt(max(b * b - a * c, 0))) / a
	} else {
		d := g.end - g.start
		t = ((q.x - g.start.x) * d.x + (q.y - g.start.y) * d.y) / (d.x * d.x + d.y * d.y)
	}
	switch g.spread {
	case .Pad:
		t = clamp(t, 0, 1)
	case .Repeat:
		t -= math.floor(t)
	case .Reflect:
		t = abs(t)
		t -= 2 * math.floor(t / 2)
		if t > 1 {t = 2 - t}
	}
	if !is_finite(t) {t = 0}
	return pc.lut[int(t * (GRADIENT_LUT_SIZE - 1) + 0.5)]
}
