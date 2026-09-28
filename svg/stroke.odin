package svg

import "core:math"

// Strokes are built as a union of small polygons (one quad per segment plus
// join and cap pieces) in the shape's user space, so non-uniform transforms
// distort the pen correctly, and each piece is mapped to device space and
// accumulated with positive winding (see `raster_positive_polygon`).
@(private)
Stroker :: struct {
	r:           ^Rasterizer,
	m:           Transform, // user -> device
	hw:          f64, // half the stroke width, user units
	join:        Line_Join,
	cap:         Line_Cap,
	miter_limit: f64,
	cull:        Rect, // user-space area that can affect the region
	// Angle step for round joins/caps: small enough that the chord of an
	// arc of radius `hw` (in device pixels) stays within tolerance.
	arc_step:    f64,
	scratch:     [dynamic]Vec2,
}

@(private)
stroke_path :: proc(r: ^Rasterizer, path: Path, m: Transform, s: Stroke) {
	inv, ok := transform_invert(m)
	if !ok {return}
	max_scale := transform_max_scale(m)
	if !(max_scale > 0) {return}
	tol := FLATTEN_TOLERANCE / max_scale
	reach := stroke_reach(s)

	region := Rect{{f64(r.x), f64(r.y)}, {f64(r.x + r.w), f64(r.y + r.h)}}
	cull := rect_expand(rect_transform(inv, rect_expand(region, 1)), reach + tol)

	st := Stroker {
		r           = r,
		m           = m,
		hw          = s.width / 2,
		join        = s.join,
		cap         = s.cap,
		miter_limit = s.miter_limit,
		cull        = cull,
	}
	radius_px := st.hw * max_scale
	st.arc_step = radius_px > FLATTEN_TOLERANCE ? 2 * math.acos(1 - FLATTEN_TOLERANCE / radius_px) : math.PI / 4
	st.arc_step = max(st.arc_step, 2 * math.PI / 4096)
	st.scratch = make([dynamic]Vec2, context.temp_allocator)

	polylines := make([dynamic]Polyline, context.temp_allocator)
	flatten_path(path, IDENTITY, tol, cull, &polylines, measure = len(s.dashes) > 0)
	if len(s.dashes) > 0 {
		polylines = apply_dashes(polylines[:], s.dashes, s.dash_offset)
	}
	for &pl in polylines {
		stroke_polyline(&st, &pl)
	}
}

@(private = "file")
stroke_polyline :: proc(st: ^Stroker, pl: ^Polyline) {
	// Drop repeated points: they have no direction to stroke along.
	pts := pl.pts[:0]
	for p in pl.pts {
		if len(pts) == 0 || p != pts[len(pts) - 1] {
			n := len(pts)
			pts = pl.pts[:n + 1]
			pts[n] = p
		}
	}
	closed := pl.closed
	if closed && len(pts) > 1 && pts[0] == pts[len(pts) - 1] {
		pts = pts[:len(pts) - 1]
	}

	if len(pts) == 1 {
		// Zero-length subpath: round and square caps still draw a dot.
		switch st.cap {
		case .Round:
			arc_piece(st, pts[0], 0, 2 * math.PI, false)
		case .Square:
			p, h := pts[0], st.hw
			piece(st, {p + {-h, -h}, p + {h, -h}, p + {h, h}, p + {-h, h}})
		case .Butt:
		}
		return
	}
	if len(pts) == 2 {closed = false}

	n := len(pts)
	segs := closed ? n : n - 1
	for i in 0 ..< segs {
		a, b := pts[i], pts[(i + 1) % n]
		bb := EMPTY_RECT
		rect_add_point(&bb, a)
		rect_add_point(&bb, b)
		if !rect_intersects(bb, st.cull) {continue}
		nrm := perp(normalize(b - a)) * st.hw
		piece(st, {a + nrm, b + nrm, b - nrm, a - nrm})
	}

	first, last := 1, n - 2
	if closed {first, last = 0, n - 1}
	for i in first ..= last {
		v := pts[i]
		if !(v.x >= st.cull.min.x && v.x <= st.cull.max.x && v.y >= st.cull.min.y && v.y <= st.cull.max.y) {continue}
		prev := pts[(i + n - 1) % n]
		next := pts[(i + 1) % n]
		join(st, v, normalize(v - prev), normalize(next - v))
	}

	if !closed {
		cap(st, pts[0], normalize(pts[0] - pts[1]))
		cap(st, pts[n - 1], normalize(pts[n - 1] - pts[n - 2]))
	}
}

@(private = "file")
join :: proc(st: ^Stroker, v, d0, d1: Vec2) {
	cross := d0.x * d1.y - d0.y * d1.x
	dot := d0.x * d1.x + d0.y * d1.y
	if abs(cross) < 1e-12 && dot > 0 {return}

	// The gap to fill is on the outside of the turn.
	o := cross > 0 ? -1.0 : 1.0
	a := v + o * perp(d0) * st.hw
	b := v + o * perp(d1) * st.hw

	switch st.join {
	case .Bevel:
		piece(st, {v, a, b})
	case .Miter:
		// Miter length / stroke width = 1 / sin(theta / 2), where theta is
		// the angle between the segments; cos(turn) = dot.
		if dot > -1 + 1e-12 {
			ratio := 1 / math.sqrt((1 + dot) / 2)
			if ratio <= st.miter_limit {
				tip := v + normalize(a + b - 2 * v) * st.hw * ratio
				piece(st, {v, a, tip, b})
				return
			}
		}
		piece(st, {v, a, b})
	case .Round:
		start := math.atan2(a.y - v.y, a.x - v.x)
		sweep := math.atan2(b.y - v.y, b.x - v.x) - start
		for sweep > math.PI {sweep -= 2 * math.PI}
		for sweep < -math.PI {sweep += 2 * math.PI}
		arc_piece(st, v, start, sweep, true)
	}
}

// `d` is the direction pointing out of the line at `p`.
@(private = "file")
cap :: proc(st: ^Stroker, p, d: Vec2) {
	nrm := perp(d) * st.hw
	switch st.cap {
	case .Butt:
	case .Square:
		ext := d * st.hw
		piece(st, {p + nrm, p + nrm + ext, p - nrm + ext, p - nrm})
	case .Round:
		// perp(d) is d rotated +90 degrees, so sweeping -180 from it passes
		// through d, the outward side.
		arc_piece(st, p, math.atan2(nrm.y, nrm.x), -math.PI, true)
	}
}

// A fan around `center` spanning `sweep` radians from angle `start`,
// including the center point when `with_center`.
@(private = "file")
arc_piece :: proc(st: ^Stroker, center: Vec2, start, sweep: f64, with_center: bool) {
	steps := max(int(math.ceil(abs(sweep) / st.arc_step)), 2)
	clear(&st.scratch)
	if with_center {append(&st.scratch, center)}
	for i in 0 ..= steps {
		s, c := math.sincos(start + sweep * f64(i) / f64(steps))
		append(&st.scratch, center + Vec2{c, s} * st.hw)
	}
	piece_points(st, st.scratch[:])
}

@(private = "file")
piece :: proc(st: ^Stroker, pts: []Vec2) {
	clear(&st.scratch)
	append(&st.scratch, ..pts)
	piece_points(st, st.scratch[:])
}

@(private = "file")
piece_points :: proc(st: ^Stroker, pts: []Vec2) {
	for &p in pts {
		p = transform_point(st.m, p)
	}
	raster_positive_polygon(st.r, pts)
}

@(private = "file")
perp :: proc(d: Vec2) -> Vec2 {
	return {-d.y, d.x}
}

@(private = "file")
normalize :: proc(v: Vec2) -> Vec2 {
	l := math.sqrt(v.x * v.x + v.y * v.y)
	return l > 0 ? v / l : {1, 0}
}

// Splits polylines into dashes. Each subpath restarts the pattern.
@(private = "file")
apply_dashes :: proc(polylines: []Polyline, dashes: []f64, offset: f64) -> [dynamic]Polyline {
	out := make([dynamic]Polyline, context.temp_allocator)
	total := 0.0
	for d in dashes {total += d}

	for pl in polylines {
		// Pattern state at the start of the subpath.
		idx := 0
		phase := math.mod(offset, total)
		if phase < 0 {phase += total}
		for phase >= dashes[idx] {
			phase -= dashes[idx]
			idx = (idx + 1) % len(dashes)
		}
		rem := dashes[idx] - phase
		on := idx % 2 == 0

		cur: ^Polyline
		start_dash :: proc(out: ^[dynamic]Polyline, at: Vec2) -> ^Polyline {
			append(out, Polyline{pts = make([dynamic]Vec2, context.temp_allocator)})
			pl := &out[len(out) - 1]
			append(&pl.pts, at)
			return pl
		}
		if on && len(pl.pts) > 0 {cur = start_dash(&out, pl.pts[0])}

		n := len(pl.pts)
		segs := pl.closed ? n : n - 1
		for i in 0 ..< segs {
			a, b := pl.pts[i], pl.pts[(i + 1) % n]
			seg := b - a
			length := math.sqrt(seg.x * seg.x + seg.y * seg.y)
			// A culled chord stands in for a longer curve: walk the curve's
			// length so later dashes stay in phase. Where the dashes fall
			// along the chord doesn't matter; it's all off-screen.
			if i + 1 < n && pl.arc[i + 1] >= 0 {length = pl.arc[i + 1]}
			pos := 0.0
			for length - pos > rem {
				pos += rem
				p := a + seg * (pos / length)
				if on {
					append(&cur.pts, p)
				} else {
					cur = start_dash(&out, p)
				}
				on = !on
				idx = (idx + 1) % len(dashes)
				rem = dashes[idx]
			}
			rem -= length - pos
			if on {append(&cur.pts, b)}
		}
	}
	return out
}
