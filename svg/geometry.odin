package svg

import "core:math"

Vec2 :: [2]f64

// Affine transform mapping (x, y) to (a*x + c*y + e, b*x + d*y + f): the same
// layout as SVG's `matrix(a b c d e f)`.
//
// Everything geometric in this package is f64. The viewer zooms far enough
// that device coordinates reach ~1e11, and f32's 24-bit mantissa would put
// edges tens of pixels off long before that; f64 keeps them well under one.
Transform :: struct {
	a, b, c, d, e, f: f64,
}

IDENTITY :: Transform{1, 0, 0, 1, 0, 0}

translate :: proc(x, y: f64) -> Transform {
	return {1, 0, 0, 1, x, y}
}

scale :: proc(x, y: f64) -> Transform {
	return {x, 0, 0, y, 0, 0}
}

rotate :: proc(degrees: f64) -> Transform {
	s, c := math.sincos(math.to_radians(degrees))
	return {c, s, -s, c, 0, 0}
}

// Returns the transform that applies `inner` first, then `outer`.
transform_mul :: proc(outer, inner: Transform) -> Transform {
	return {
		a = outer.a * inner.a + outer.c * inner.b,
		b = outer.b * inner.a + outer.d * inner.b,
		c = outer.a * inner.c + outer.c * inner.d,
		d = outer.b * inner.c + outer.d * inner.d,
		e = outer.a * inner.e + outer.c * inner.f + outer.e,
		f = outer.b * inner.e + outer.d * inner.f + outer.f,
	}
}

transform_point :: proc(t: Transform, p: Vec2) -> Vec2 {
	return {t.a * p.x + t.c * p.y + t.e, t.b * p.x + t.d * p.y + t.f}
}

transform_invert :: proc(t: Transform) -> (inv: Transform, ok: bool) {
	det := t.a * t.d - t.b * t.c
	if det == 0 || !is_finite(det) {
		return {}, false
	}
	r := 1 / det
	return {
			a = t.d * r,
			b = -t.b * r,
			c = -t.c * r,
			d = t.a * r,
			e = (t.c * t.f - t.d * t.e) * r,
			f = (t.b * t.e - t.a * t.f) * r,
		},
		true
}

transform_is_identity :: proc(t: Transform) -> bool {
	return t == IDENTITY
}

// Largest factor by which `t` stretches any vector (its largest singular
// value). Used to turn a device-space flattening tolerance into user space.
transform_max_scale :: proc(t: Transform) -> f64 {
	p := t.a * t.a + t.b * t.b + t.c * t.c + t.d * t.d
	det := t.a * t.d - t.b * t.c
	disc := max(p * p - 4 * det * det, 0)
	return math.sqrt((p + math.sqrt(disc)) / 2)
}

is_finite :: proc(v: f64) -> bool {
	c := math.classify(v)
	return c != .Inf && c != .Neg_Inf && c != .NaN
}

Rect :: struct {
	min, max: Vec2,
}

EMPTY_RECT :: Rect{{math.INF_F64, math.INF_F64}, {math.NEG_INF_F64, math.NEG_INF_F64}}

rect_is_empty :: proc(r: Rect) -> bool {
	return !(r.min.x <= r.max.x && r.min.y <= r.max.y)
}

rect_add_point :: proc(r: ^Rect, p: Vec2) {
	r.min = {min(r.min.x, p.x), min(r.min.y, p.y)}
	r.max = {max(r.max.x, p.x), max(r.max.y, p.y)}
}

rect_union :: proc(a, b: Rect) -> Rect {
	if rect_is_empty(a) {return b}
	if rect_is_empty(b) {return a}
	return {{min(a.min.x, b.min.x), min(a.min.y, b.min.y)}, {max(a.max.x, b.max.x), max(a.max.y, b.max.y)}}
}

rect_intersects :: proc(a, b: Rect) -> bool {
	return a.min.x <= b.max.x && b.min.x <= a.max.x && a.min.y <= b.max.y && b.min.y <= a.max.y
}

rect_expand :: proc(r: Rect, by: f64) -> Rect {
	if rect_is_empty(r) {return r}
	return {r.min - by, r.max + by}
}

// Bounding box of `r`'s four corners after transforming them.
rect_transform :: proc(t: Transform, r: Rect) -> Rect {
	if rect_is_empty(r) {return r}
	out := EMPTY_RECT
	rect_add_point(&out, transform_point(t, r.min))
	rect_add_point(&out, transform_point(t, r.max))
	rect_add_point(&out, transform_point(t, {r.min.x, r.max.y}))
	rect_add_point(&out, transform_point(t, {r.max.x, r.min.y}))
	return out
}

Verb :: enum u8 {
	Move, // 1 point
	Line, // 1 point
	Cubic, // 3 points: two controls, then the end point
	Close, // 0 points
}

// A path in its own user space. Quadratics and arcs are converted to cubics
// while parsing, so rendering only has to deal with these four verbs.
Path :: struct {
	verbs:  [dynamic]Verb,
	points: [dynamic]Vec2,
}

path_move_to :: proc(p: ^Path, pt: Vec2) {
	// Consecutive moves collapse: only the last one starts a subpath.
	if n := len(p.verbs); n > 0 && p.verbs[n - 1] == .Move {
		p.points[len(p.points) - 1] = pt
		return
	}
	append(&p.verbs, Verb.Move)
	append(&p.points, pt)
}

path_line_to :: proc(p: ^Path, pt: Vec2) {
	append(&p.verbs, Verb.Line)
	append(&p.points, pt)
}

path_cubic_to :: proc(p: ^Path, c1, c2, pt: Vec2) {
	append(&p.verbs, Verb.Cubic)
	append(&p.points, c1, c2, pt)
}

path_close :: proc(p: ^Path) {
	if n := len(p.verbs); n > 0 && p.verbs[n - 1] != .Close {
		append(&p.verbs, Verb.Close)
	}
}

// True if the path draws anything beyond bare move-tos.
path_has_segments :: proc(p: Path) -> bool {
	for v in p.verbs {
		if v == .Line || v == .Cubic {return true}
	}
	return false
}

// Exact bounds of the path's geometry (curve extrema, not control points).
path_bounds :: proc(p: Path) -> Rect {
	r := EMPTY_RECT
	pi := 0
	cur: Vec2
	for v in p.verbs {
		switch v {
		case .Move, .Line:
			cur = p.points[pi]
			rect_add_point(&r, cur)
			pi += 1
		case .Cubic:
			c1, c2, end := p.points[pi], p.points[pi + 1], p.points[pi + 2]
			rect_add_point(&r, end)
			for axis in 0 ..< 2 {
				ts, n := cubic_extrema(cur[axis], c1[axis], c2[axis], end[axis])
				for t in ts[:n] {
					rect_add_point(&r, cubic_eval(cur, c1, c2, end, t))
				}
			}
			cur = end
			pi += 3
		case .Close:
		}
	}
	return r
}

// Bounds of the path's points including control points: cheaper than
// `path_bounds` and still a superset, which is all culling needs.
path_control_bounds :: proc(p: Path, t: Transform) -> Rect {
	r := EMPTY_RECT
	for pt in p.points {
		rect_add_point(&r, transform_point(t, pt))
	}
	return r
}

cubic_eval :: proc(p0, p1, p2, p3: Vec2, t: f64) -> Vec2 {
	mt := 1 - t
	return mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3
}

// Parameters in (0, 1) where one coordinate of a cubic has a local extremum.
@(private)
cubic_extrema :: proc(p0, p1, p2, p3: f64) -> (ts: [2]f64, n: int) {
	// Derivative / 3: a t^2 + b t + c
	a := -p0 + 3 * p1 - 3 * p2 + p3
	b := 2 * (p0 - 2 * p1 + p2)
	c := p1 - p0
	push :: proc(ts: ^[2]f64, n: ^int, t: f64) {
		if t > 0 && t < 1 {
			ts[n^] = t
			n^ += 1
		}
	}
	if abs(a) < 1e-12 {
		if abs(b) > 1e-12 {push(&ts, &n, -c / b)}
		return
	}
	disc := b * b - 4 * a * c
	if disc < 0 {return}
	sq := math.sqrt(disc)
	push(&ts, &n, (-b + sq) / (2 * a))
	push(&ts, &n, (-b - sq) / (2 * a))
	return
}

// Appends an SVG elliptical arc from `from` to `to` as cubic segments,
// following the endpoint-to-center conversion in SVG 1.1 appendix F.6.
path_arc_to :: proc(p: ^Path, from: Vec2, radius_x, radius_y, x_axis_rotation: f64, large_arc, sweep: bool, to: Vec2) {
	if from == to {return}
	rx, ry := abs(radius_x), abs(radius_y)
	if rx == 0 || ry == 0 {
		path_line_to(p, to)
		return
	}

	sin_phi, cos_phi := math.sincos(math.to_radians(x_axis_rotation))
	half := (from - to) / 2
	x1 := cos_phi * half.x + sin_phi * half.y
	y1 := -sin_phi * half.x + cos_phi * half.y

	// Scale radii up if they can't span the endpoints.
	lambda := (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
	if lambda > 1 {
		s := math.sqrt(lambda)
		rx *= s
		ry *= s
	}

	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	coef := den == 0 ? 0 : math.sqrt(max(num / den, 0))
	if large_arc == sweep {coef = -coef}
	cxp := coef * rx * y1 / ry
	cyp := -coef * ry * x1 / rx
	mid := (from + to) / 2
	center := Vec2{cos_phi * cxp - sin_phi * cyp + mid.x, sin_phi * cxp + cos_phi * cyp + mid.y}

	angle :: proc(u, v: Vec2) -> f64 {
		return math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
	}
	u := Vec2{(x1 - cxp) / rx, (y1 - cyp) / ry}
	v := Vec2{(-x1 - cxp) / rx, (-y1 - cyp) / ry}
	theta1 := angle({1, 0}, u)
	dtheta := angle(u, v)
	if !sweep && dtheta > 0 {dtheta -= 2 * math.PI}
	if sweep && dtheta < 0 {dtheta += 2 * math.PI}

	segments := max(int(math.ceil(abs(dtheta) / (math.PI / 2) - 1e-9)), 1)
	delta := dtheta / f64(segments)
	k := 4.0 / 3.0 * math.tan(delta / 4)

	map_point :: proc(center: Vec2, rx, ry, sin_phi, cos_phi: f64, q: Vec2) -> Vec2 {
		return {
			center.x + rx * cos_phi * q.x - ry * sin_phi * q.y,
			center.y + rx * sin_phi * q.x + ry * cos_phi * q.y,
		}
	}
	for i in 0 ..< segments {
		a1 := theta1 + f64(i) * delta
		a2 := a1 + delta
		s1, c1 := math.sincos(a1)
		s2, c2 := math.sincos(a2)
		ctrl1 := Vec2{c1 - k * s1, s1 + k * c1}
		ctrl2 := Vec2{c2 + k * s2, s2 - k * c2}
		end := i == segments - 1 ? to : map_point(center, rx, ry, sin_phi, cos_phi, {c2, s2})
		path_cubic_to(
			p,
			map_point(center, rx, ry, sin_phi, cos_phi, ctrl1),
			map_point(center, rx, ry, sin_phi, cos_phi, ctrl2),
			end,
		)
	}
}

path_add_ellipse :: proc(p: ^Path, cx, cy, rx, ry: f64) {
	path_move_to(p, {cx + rx, cy})
	path_arc_to(p, {cx + rx, cy}, rx, ry, 0, false, true, {cx, cy + ry})
	path_arc_to(p, {cx, cy + ry}, rx, ry, 0, false, true, {cx - rx, cy})
	path_arc_to(p, {cx - rx, cy}, rx, ry, 0, false, true, {cx, cy - ry})
	path_arc_to(p, {cx, cy - ry}, rx, ry, 0, false, true, {cx + rx, cy})
	path_close(p)
}

path_add_rect :: proc(p: ^Path, x, y, w, h, rx, ry: f64) {
	if rx <= 0 || ry <= 0 {
		path_move_to(p, {x, y})
		path_line_to(p, {x + w, y})
		path_line_to(p, {x + w, y + h})
		path_line_to(p, {x, y + h})
		path_close(p)
		return
	}
	path_move_to(p, {x + rx, y})
	path_line_to(p, {x + w - rx, y})
	path_arc_to(p, {x + w - rx, y}, rx, ry, 0, false, true, {x + w, y + ry})
	path_line_to(p, {x + w, y + h - ry})
	path_arc_to(p, {x + w, y + h - ry}, rx, ry, 0, false, true, {x + w - rx, y + h})
	path_line_to(p, {x + rx, y + h})
	path_arc_to(p, {x + rx, y + h}, rx, ry, 0, false, true, {x, y + h - ry})
	path_line_to(p, {x, y + ry})
	path_arc_to(p, {x, y + ry}, rx, ry, 0, false, true, {x + rx, y})
	path_close(p)
}

@(private)
math_tan_deg :: proc(degrees: f64) -> f64 {
	return math.tan(math.to_radians(degrees))
}
