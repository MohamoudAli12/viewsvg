package svg

import "core:math"

// Maximum distance, in device pixels, between a curve and the polyline that
// approximates it.
@(private)
FLATTEN_TOLERANCE :: 0.1

// Signed-area coverage accumulator over a rectangular region of device space.
//
// Each line adds, per pixel it passes through, the change in coverage that
// pixel contributes to everything to its right; a prefix sum along the row
// then yields exact analytic area coverage. The result is the winding number
// blended with antialiasing, which is folded into [0, 1] per fill rule.
@(private)
Rasterizer :: struct {
	acc:              [dynamic]f32,
	x, y:             int, // device position of the region's top-left pixel
	w, h:             int,
	stride:           int,
	row_min, row_max: int, // rows touched since the last reset
}

// Starts accumulating over the device region (x, y, w, h). `acc` is kept
// all-zero between uses (reading coverage clears the rows it reads), so no
// clearing is needed here.
@(private)
raster_reset :: proc(r: ^Rasterizer, x, y, w, h: int) {
	r.x, r.y, r.w, r.h = x, y, w, h
	r.stride = w + 2
	if need := r.stride * h; len(r.acc) < need {
		resize(&r.acc, need)
	}
	r.row_min = h
	r.row_max = -1
}

// Adds the edge p0 -> p1 (device coordinates) with the given winding sign.
@(private)
raster_line :: proc(r: ^Rasterizer, p0, p1: Vec2, sign: f64 = 1) {
	a := p0 - {f64(r.x), f64(r.y)}
	b := p1 - {f64(r.x), f64(r.y)}
	h := f64(r.h)
	if a.y == b.y || (a.y <= 0 && b.y <= 0) || (a.y >= h && b.y >= h) {return}
	if !(is_finite(a.x) && is_finite(a.y) && is_finite(b.x) && is_finite(b.y)) {return}

	// Split where the edge crosses the region's left/right sides. Parts left
	// of the region still matter (they cover every pixel to their right), so
	// they are pinned to x = 0; parts right of it affect nothing visible and
	// are pinned to x = w.
	w := f64(r.w)
	ts: [4]f64
	n := 0
	ts[n] = 0;n += 1
	if (a.x < 0) != (b.x < 0) {ts[n] = (0 - a.x) / (b.x - a.x);n += 1}
	if (a.x < w) != (b.x < w) {ts[n] = (w - a.x) / (b.x - a.x);n += 1}
	ts[n] = 1;n += 1
	if n == 4 && ts[1] > ts[2] {ts[1], ts[2] = ts[2], ts[1]}

	for i in 0 ..< n - 1 {
		q0 := a + (b - a) * ts[i]
		q1 := a + (b - a) * ts[i + 1]
		if i == 0 {q0 = a}
		if i == n - 2 {q1 = b}
		mid := (q0.x + q1.x) / 2
		switch {
		case mid <= 0:
			q0.x, q1.x = 0, 0
		case mid >= w:
			q0.x, q1.x = w, w
		case:
			q0.x = clamp(q0.x, 0, w)
			q1.x = clamp(q1.x, 0, w)
		}
		accumulate(r, q0, q1, sign)
	}
}

// Accumulates one edge lying within 0 <= x <= w (region-local coordinates).
@(private = "file")
accumulate :: proc(r: ^Rasterizer, p0, p1: Vec2, sign: f64) {
	if p0.y == p1.y {return}
	dir := sign
	p0, p1 := p0, p1
	if p0.y > p1.y {
		p0, p1 = p1, p0
		dir = -dir
	}
	dxdy := (p1.x - p0.x) / (p1.y - p0.y)
	y_start := max(p0.y, 0)
	y_end := min(p1.y, f64(r.h))
	if y_start >= y_end {return}
	// x at a given y, recomputed from p0 rather than stepped row by row, and
	// clamped: the edge lies within [0, w] (raster_line pins it there), but
	// rounding can push it a hair outside, which would index column -1 or
	// past the row.
	w := f64(r.w)
	x_at :: #force_inline proc(p0: Vec2, dxdy, y, w: f64) -> f64 {
		return clamp(p0.x + (y - p0.y) * dxdy, 0, w)
	}
	x := x_at(p0, dxdy, y_start, w)

	row0 := int(y_start)
	row1 := int(math.ceil(y_end))
	r.row_min = min(r.row_min, row0)
	r.row_max = max(r.row_max, row1 - 1)

	acc := r.acc[:]
	for row in row0 ..< row1 {
		line := row * r.stride
		y_next := min(f64(row + 1), y_end)
		dy := y_next - max(f64(row), y_start)
		xnext := x_at(p0, dxdy, y_next, w)
		d := dy * dir
		x0, x1 := min(x, xnext), max(x, xnext)
		x0floor := math.floor(x0)
		x0i := int(x0floor)
		x1ceil := math.ceil(x1)
		x1i := int(x1ceil)
		if x1i <= x0i + 1 {
			// Stays within one pixel column.
			xmf := 0.5 * (x + xnext) - x0floor
			acc[line + x0i] += f32(d - d * xmf)
			acc[line + x0i + 1] += f32(d * xmf)
		} else {
			s := 1 / (x1 - x0)
			x0f := x0 - x0floor
			a0 := 0.5 * s * (1 - x0f) * (1 - x0f)
			x1f := x1 - x1ceil + 1
			am := 0.5 * s * x1f * x1f
			acc[line + x0i] += f32(d * a0)
			if x1i == x0i + 2 {
				acc[line + x0i + 1] += f32(d * (1 - a0 - am))
			} else {
				a1 := s * (1.5 - x0f)
				acc[line + x0i + 1] += f32(d * (a1 - a0))
				ds := f32(d * s)
				for xi in x0i + 2 ..< x1i - 1 {
					acc[line + xi] += ds
				}
				a2 := a1 + f64(x1i - x0i - 3) * s
				acc[line + x1i - 1] += f32(d * (1 - a2 - am))
			}
			acc[line + x1i] += f32(d * am)
		}
		x = xnext
	}
}

// Resolves one row (region-local) into coverage in [0, 1] and clears it.
@(private)
raster_row_coverage :: proc(r: ^Rasterizer, row: int, rule: Fill_Rule, out: []f32) {
	line := r.acc[row * r.stride:][:r.stride]
	sum: f32 = 0
	switch rule {
	case .Non_Zero:
		for i in 0 ..< r.w {
			sum += line[i]
			line[i] = 0
			out[i] = min(abs(sum), 1)
		}
	case .Even_Odd:
		for i in 0 ..< r.w {
			sum += line[i]
			line[i] = 0
			v := abs(sum)
			v -= 2 * math.floor(v / 2)
			out[i] = v > 1 ? 2 - v : v
		}
	}
	line[r.w] = 0
	line[r.w + 1] = 0
}

@(private)
Polyline :: struct {
	pts:    [dynamic]Vec2,
	closed: bool,
	// Only filled when flattening with `measure`: arc[i] is the true length
	// of the curve between pts[i-1] and pts[i] when that segment is a culled
	// chord standing in for a longer curve, and -1 otherwise.
	arc:    [dynamic]f64,
}

// Flattens `path` (mapped through `m`) into polylines, one per subpath.
// Curves are split until each piece is within `tol` of the true curve, except
// that any piece whose control points all lie outside `cull` is replaced by
// its chord. The chord stays inside the control polygon, so it stays outside
// `cull` too; that keeps flattening cost proportional to what is visible even
// when a deep zoom puts most of a curve millions of pixels off-screen.
//
// Dashing needs true lengths even for culled pieces, since the dash phase
// on-screen depends on everything before it; `measure` records them.
@(private)
flatten_path :: proc(path: Path, m: Transform, tol: f64, cull: Maybe(Rect), out: ^[dynamic]Polyline, measure := false) {
	pi := 0
	start: Vec2
	cur: ^Polyline
	begin :: proc(out: ^[dynamic]Polyline, at: Vec2, measure: bool) -> ^Polyline {
		append(out, Polyline{})
		pl := &out[len(out) - 1]
		pl.pts = make([dynamic]Vec2, context.temp_allocator)
		append(&pl.pts, at)
		if measure {
			pl.arc = make([dynamic]f64, context.temp_allocator)
			append(&pl.arc, -1)
		}
		return pl
	}
	for v in path.verbs {
		switch v {
		case .Move:
			start = transform_point(m, path.points[pi])
			cur = begin(out, start, measure)
			pi += 1
		case .Line:
			if cur == nil || cur.closed {cur = begin(out, start, measure)}
			append(&cur.pts, transform_point(m, path.points[pi]))
			if measure {append(&cur.arc, -1)}
			pi += 1
		case .Cubic:
			if cur == nil || cur.closed {cur = begin(out, start, measure)}
			p0 := cur.pts[len(cur.pts) - 1]
			flatten_cubic(
				cur,
				p0,
				transform_point(m, path.points[pi]),
				transform_point(m, path.points[pi + 1]),
				transform_point(m, path.points[pi + 2]),
				tol,
				cull,
				measure,
				0,
			)
			pi += 3
		case .Close:
			if cur != nil {cur.closed = true}
		}
	}
}

@(private = "file")
flatten_cubic :: proc(out: ^Polyline, p0, p1, p2, p3: Vec2, tol: f64, cull: Maybe(Rect), measure: bool, depth: int) {
	emit :: proc(out: ^Polyline, p: Vec2, measure: bool, arc: f64 = -1) {
		append(&out.pts, p)
		if measure {append(&out.arc, arc)}
	}
	if c, has := cull.?; has {
		bb := EMPTY_RECT
		rect_add_point(&bb, p0)
		rect_add_point(&bb, p1)
		rect_add_point(&bb, p2)
		rect_add_point(&bb, p3)
		if !rect_intersects(bb, c) {
			emit(out, p3, measure, measure ? cubic_length(p0, p1, p2, p3, 0) : -1)
			return
		}
	}
	dd1 := p0 - 2 * p1 + p2
	dd2 := p1 - 2 * p2 + p3
	dd := math.sqrt(max(dd1.x * dd1.x + dd1.y * dd1.y, dd2.x * dd2.x + dd2.y * dd2.y))
	nf := math.ceil(math.sqrt(0.75 * dd / tol))
	if !is_finite(nf) {return}
	if nf > 16 && depth < 48 {
		// Split in half (de Casteljau) so culling can discard the
		// off-screen half before it is subdivided any further.
		a, b := split_cubic(p0, p1, p2, p3)
		flatten_cubic(out, a[0], a[1], a[2], a[3], tol, cull, measure, depth + 1)
		flatten_cubic(out, b[0], b[1], b[2], b[3], tol, cull, measure, depth + 1)
		return
	}
	n := clamp(int(nf), 1, 4096)
	for i in 1 ..< n {
		emit(out, cubic_eval(p0, p1, p2, p3, f64(i) / f64(n)), measure)
	}
	emit(out, p3, measure)
}

@(private = "file")
split_cubic :: proc(p0, p1, p2, p3: Vec2) -> (a, b: [4]Vec2) {
	p01 := (p0 + p1) / 2
	p12 := (p1 + p2) / 2
	p23 := (p2 + p3) / 2
	p012 := (p01 + p12) / 2
	p123 := (p12 + p23) / 2
	mid := (p012 + p123) / 2
	return {p0, p01, p012, mid}, {mid, p123, p23, p3}
}

// Arc length of a cubic: 5-point Gauss-Legendre per piece, splitting until
// the halves agree with the whole.
@(private = "file")
cubic_length :: proc(p0, p1, p2, p3: Vec2, depth: int) -> f64 {
	gauss :: proc(p0, p1, p2, p3: Vec2) -> f64 {
		@(static, rodata)
		nodes := [5]f64{0, -0.5384693101056831, 0.5384693101056831, -0.9061798459386640, 0.9061798459386640}
		@(static, rodata)
		weights := [5]f64{0.5688888888888889, 0.4786286704993665, 0.4786286704993665, 0.2369268850561891, 0.2369268850561891}
		sum := 0.0
		for i in 0 ..< 5 {
			t := 0.5 * nodes[i] + 0.5
			mt := 1 - t
			d := 3 * mt * mt * (p1 - p0) + 6 * mt * t * (p2 - p1) + 3 * t * t * (p3 - p2)
			sum += weights[i] * math.sqrt(d.x * d.x + d.y * d.y)
		}
		return 0.5 * sum
	}
	whole := gauss(p0, p1, p2, p3)
	a, b := split_cubic(p0, p1, p2, p3)
	halves := gauss(a[0], a[1], a[2], a[3]) + gauss(b[0], b[1], b[2], b[3])
	if depth >= 16 || abs(whole - halves) <= 1e-12 * halves {return halves}
	return cubic_length(a[0], a[1], a[2], a[3], depth + 1) + cubic_length(b[0], b[1], b[2], b[3], depth + 1)
}

// Adds a closed polygon, oriented so that it winds positively. Stroke
// outlines are drawn as many overlapping pieces; with every piece positive,
// overlaps only ever add coverage (clamped to 1) instead of cancelling out.
@(private)
raster_positive_polygon :: proc(r: ^Rasterizer, pts: []Vec2) {
	n := len(pts)
	if n < 3 {return}
	area := 0.0
	for i in 0 ..< n {
		a, b := pts[i], pts[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	}
	if area == 0 || !is_finite(area) {return}
	sign := area > 0 ? 1.0 : -1.0
	for i in 0 ..< n {
		raster_line(r, pts[i], pts[(i + 1) % n], sign)
	}
}
