package svg

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// Resolution state while converting the XML tree into a render tree.
// Everything is allocated from the document's arena.
@(private)
Parser :: struct {
	x:           ^Xml_Document,
	ids:         map[string]Element_ID,
	rules:       [dynamic]Css_Rule,
	gradients:   map[Element_ID]^Gradient,
	// A clip path maps to nil while it is being resolved, which is how a
	// clip-path cycle is detected (and treated as no clip).
	clips:       map[Element_ID]^Clip_Path,
	use_stack:   [dynamic]Element_ID,
	unsupported: map[string]bool,
	// Size that percentages resolve against: the nearest viewBox.
	viewport:    Vec2,
}

// Bound on nested `<use>` expansion, so a document can't make the tree
// blow up exponentially.
@(private = "file")
MAX_USE_DEPTH :: 24

@(private)
parse_document :: proc(doc: ^Document, data: []u8) -> (ok: bool, err: string) {
	x, xerr := parse_xml(string(data))
	if msg, failed := xerr.?; failed {
		return false, msg
	}
	if len(x.elements) == 0 || local_name(x.elements[0].ident) != "svg" {
		return false, "root element is not <svg>"
	}

	p := Parser{x = x}
	for &el, i in x.elements {
		if id, has := attr(&el, "id"); has && id not_in p.ids {
			p.ids[id] = Element_ID(i)
		}
		if local_name(el.ident) == "style" {
			if t, has := attr(&el, "type"); has && t != "" && t != "text/css" {continue}
			for v in el.value {
				if text, is_text := v.(string); is_text {
					parse_stylesheet(text, &p.rules)
				}
			}
		}
	}

	root := &x.elements[0]
	vb, has_vb := parse_viewbox(root)
	size_attr :: proc(el: ^Element, name: string, fallback: f64) -> f64 {
		s, has := attr(el, name)
		if !has || strings.has_suffix(trim(s), "%") {return fallback}
		v, ok := parse_length(s, .Other, {})
		return ok ? v : fallback
	}
	doc.width = size_attr(root, "width", has_vb ? vb[2] : 100)
	doc.height = size_attr(root, "height", has_vb ? vb[3] : 100)
	if !(doc.width > 0 && doc.height > 0) {
		return false, "SVG has zero size"
	}

	root_ts := IDENTITY
	p.viewport = {doc.width, doc.height}
	if has_vb {
		root_ts = viewbox_transform(vb, parse_aspect_ratio(root), doc.width, doc.height)
		p.viewport = {vb[2], vb[3]}
	}

	base := default_style()
	style := compute_style(&p, 0, &base)
	children: [dynamic]Node
	if style.displayed {
		convert_children(&p, 0, &style, &children)
	}
	doc.root = make_group(root_ts, style.opacity, nil, children)

	extent := max(doc.width, doc.height)
	root_bounds := node_bounds(doc.root)
	if !rect_is_empty(root_bounds) {
		for v in ([4]f64{root_bounds.min.x, root_bounds.min.y, root_bounds.max.x, root_bounds.max.y}) {
			if is_finite(v) {extent = max(extent, abs(v))}
		}
	}
	doc.coord_extent = max(extent, 1)

	names, _ := slice.map_keys(p.unsupported)
	slice.sort(names)
	for name in names {
		append(&doc.warnings, fmt.aprintf("%s is not supported and was skipped", name))
	}
	return true, ""
}

@(private)
local_name :: proc(s: string) -> string {
	if i := strings.last_index_byte(s, ':'); i >= 0 {
		return s[i + 1:]
	}
	return s
}

// Looks up an attribute by local name, so `href` also finds `xlink:href`.
@(private)
attr :: proc(el: ^Element, name: string) -> (value: string, ok: bool) {
	for a in el.attribs {
		if a.key == name {return a.val, true}
	}
	for a in el.attribs {
		if local_name(a.key) == name {return a.val, true}
	}
	return "", false
}

@(private)
length_attr :: proc(p: ^Parser, el: ^Element, name: string, axis: Axis, fallback: f64) -> f64 {
	s, has := attr(el, name)
	if !has {return fallback}
	v, ok := parse_length(s, axis, p.viewport)
	return ok ? v : fallback
}

@(private)
note_unsupported :: proc(p: ^Parser, what: string) {
	p.unsupported[what] = true
}

@(private = "file")
convert_children :: proc(p: ^Parser, id: Element_ID, style: ^Style, out: ^[dynamic]Node) {
	for v in p.x.elements[id].value {
		if child, ok := v.(Element_ID); ok {
			convert_element(p, child, style, out)
		}
	}
}

@(private = "file")
convert_element :: proc(p: ^Parser, id: Element_ID, parent: ^Style, out: ^[dynamic]Node) {
	el := &p.x.elements[id]
	tag := local_name(el.ident)
	switch tag {
	case "g", "a", "switch", "svg", "use", "text", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
	case "image":
		note_unsupported(p, "<image>")
		return
	case "foreignObject":
		note_unsupported(p, "<foreignObject>")
		return
	case:
		return // defs, clipPath, gradients, symbol, style, metadata, ...
	}

	style := compute_style(p, id, parent)
	if !style.displayed {return}
	if style.has_mask {note_unsupported(p, "mask")}
	if style.has_filter {note_unsupported(p, "filter")}

	transform := IDENTITY
	if t, has := attr(el, "transform"); has {
		transform = parse_transform(t) or_else IDENTITY
	}
	clip := resolve_clip(p, style.clip_path)

	children: [dynamic]Node
	switch tag {
	case "g", "a", "switch":
		convert_children(p, id, &style, &children)
	case "svg":
		convert_nested_svg(p, id, &style, &children)
	case "use":
		convert_use(p, el, &style, &children, &transform)
	case "text":
		convert_text(p, id, &style, &children)
	case:
		if shape := convert_shape(p, el, tag, &style); shape != nil {
			append(&children, Node(shape))
		}
	}
	if len(children) == 0 {return}

	if style.opacity >= 1 && clip == nil {
		if transform_is_identity(transform) {
			append(out, ..children[:])
			return
		}
		if len(children) == 1 {
			if shape, is_shape := children[0].(^Shape); is_shape {
				shape.transform = transform_mul(transform, shape.transform)
				shape_update_bounds(shape)
				append(out, Node(shape))
				return
			}
		}
	}
	append(out, Node(make_group(transform, style.opacity, clip, children)))
}

@(private = "file")
make_group :: proc(transform: Transform, opacity: f32, clip: ^Clip_Path, children: [dynamic]Node) -> ^Group {
	g := new(Group)
	g.transform = transform
	g.opacity = opacity
	g.clip = clip
	g.children = children
	g.bbox = EMPTY_RECT
	g.bounds = EMPTY_RECT
	for c in children {
		g.bbox = rect_union(g.bbox, node_bbox(c))
		g.bounds = rect_union(g.bounds, node_bounds(c))
	}
	return g
}

// Group wrapping `children` in a new viewport at (x, y, w, h), clipped to it
// unless `overflow` says otherwise.
@(private = "file")
make_viewport :: proc(p: ^Parser, el: ^Element, inner: Transform, x, y, w, h: f64, children: [dynamic]Node, out: ^[dynamic]Node) {
	if len(children) == 0 {return}
	content := make_group(inner, 1, nil, children)
	overflow, _ := attr(el, "overflow")
	if overflow == "visible" || overflow == "auto" {
		append(out, Node(content))
		return
	}
	clip := new(Clip_Path)
	clip.transform = IDENTITY
	item := Clip_Item{transform = IDENTITY}
	path_add_rect(&item.path, x, y, w, h, 0, 0)
	append(&clip.items, item)
	wrapper: [dynamic]Node
	append(&wrapper, Node(content))
	append(out, Node(make_group(IDENTITY, 1, clip, wrapper)))
}

@(private = "file")
convert_nested_svg :: proc(p: ^Parser, id: Element_ID, style: ^Style, out: ^[dynamic]Node) {
	el := &p.x.elements[id]
	x := length_attr(p, el, "x", .X, 0)
	y := length_attr(p, el, "y", .Y, 0)
	w := length_attr(p, el, "width", .X, p.viewport.x)
	h := length_attr(p, el, "height", .Y, p.viewport.y)
	if !(w > 0 && h > 0) {return}

	inner := translate(x, y)
	saved := p.viewport
	p.viewport = {w, h}
	if vb, has_vb := parse_viewbox(el); has_vb {
		inner = transform_mul(inner, viewbox_transform(vb, parse_aspect_ratio(el), w, h))
		p.viewport = {vb[2], vb[3]}
	}
	children: [dynamic]Node
	convert_children(p, id, style, &children)
	p.viewport = saved
	make_viewport(p, el, inner, x, y, w, h, children, out)
}

@(private = "file")
convert_use :: proc(p: ^Parser, el: ^Element, style: ^Style, out: ^[dynamic]Node, transform: ^Transform) {
	target, ok := resolve_href(p, el)
	if !ok || len(p.use_stack) >= MAX_USE_DEPTH || slice.contains(p.use_stack[:], target) {return}

	x := length_attr(p, el, "x", .X, 0)
	y := length_attr(p, el, "y", .Y, 0)
	transform^ = transform_mul(transform^, translate(x, y))

	append(&p.use_stack, target)
	defer pop(&p.use_stack)

	target_el := &p.x.elements[target]
	if local_name(target_el.ident) != "symbol" {
		convert_element(p, target, style, out)
		return
	}

	sym_style := compute_style(p, target, style)
	if !sym_style.displayed {return}
	w := length_attr(p, el, "width", .X, p.viewport.x)
	h := length_attr(p, el, "height", .Y, p.viewport.y)
	if !(w > 0 && h > 0) {return}
	inner := IDENTITY
	saved := p.viewport
	if vb, has_vb := parse_viewbox(target_el); has_vb {
		inner = viewbox_transform(vb, parse_aspect_ratio(target_el), w, h)
		p.viewport = {vb[2], vb[3]}
	}
	children: [dynamic]Node
	convert_children(p, target, &sym_style, &children)
	p.viewport = saved
	make_viewport(p, target_el, inner, 0, 0, w, h, children, out)
}

@(private = "file")
resolve_href :: proc(p: ^Parser, el: ^Element) -> (target: Element_ID, ok: bool) {
	href := attr(el, "href") or_return
	href = trim(href)
	if !strings.has_prefix(href, "#") {return}
	return p.ids[href[1:]]
}

// Geometry of a basic shape or `<path>`, in its own user space.
@(private = "file")
shape_path :: proc(p: ^Parser, el: ^Element, tag: string) -> (path: Path, ok: bool) {
	switch tag {
	case "path":
		d, _ := attr(el, "d")
		parse_path_data(d, &path)
	case "rect":
		x := length_attr(p, el, "x", .X, 0)
		y := length_attr(p, el, "y", .Y, 0)
		w := length_attr(p, el, "width", .X, 0)
		h := length_attr(p, el, "height", .Y, 0)
		if !(w > 0 && h > 0) {return}
		_, has_rx := attr(el, "rx")
		_, has_ry := attr(el, "ry")
		rx := length_attr(p, el, "rx", .X, 0)
		ry := length_attr(p, el, "ry", .Y, 0)
		if has_rx && !has_ry {ry = rx}
		if has_ry && !has_rx {rx = ry}
		path_add_rect(&path, x, y, w, h, min(max(rx, 0), w / 2), min(max(ry, 0), h / 2))
	case "circle":
		r := length_attr(p, el, "r", .Other, 0)
		if !(r > 0) {return}
		path_add_ellipse(&path, length_attr(p, el, "cx", .X, 0), length_attr(p, el, "cy", .Y, 0), r, r)
	case "ellipse":
		_, has_rx := attr(el, "rx")
		_, has_ry := attr(el, "ry")
		rx := length_attr(p, el, "rx", .X, 0)
		ry := length_attr(p, el, "ry", .Y, 0)
		if has_rx && !has_ry {ry = rx}
		if has_ry && !has_rx {rx = ry}
		if !(rx > 0 && ry > 0) {return}
		path_add_ellipse(&path, length_attr(p, el, "cx", .X, 0), length_attr(p, el, "cy", .Y, 0), rx, ry)
	case "line":
		path_move_to(&path, {length_attr(p, el, "x1", .X, 0), length_attr(p, el, "y1", .Y, 0)})
		path_line_to(&path, {length_attr(p, el, "x2", .X, 0), length_attr(p, el, "y2", .Y, 0)})
	case "polyline", "polygon":
		pts_attr, _ := attr(el, "points")
		nums := parse_number_list(pts_attr)
		if len(nums) < 4 {return}
		path_move_to(&path, {nums[0], nums[1]})
		for i := 2; i + 1 < len(nums); i += 2 {
			path_line_to(&path, {nums[i], nums[i + 1]})
		}
		if tag == "polygon" {path_close(&path)}
	case:
		return
	}
	return path, path_has_segments(path)
}

@(private = "file")
convert_shape :: proc(p: ^Parser, el: ^Element, tag: string, style: ^Style) -> ^Shape {
	if !style.visible {return nil}
	path, ok := shape_path(p, el, tag)
	if !ok {return nil}
	return make_shape(p, path, style)
}

// A shape painted per `style`, or nil if it would paint nothing.
@(private)
make_shape :: proc(p: ^Parser, path: Path, style: ^Style) -> ^Shape {
	bbox := path_bounds(path)

	shape := new(Shape)
	shape.transform = IDENTITY
	shape.path = path
	shape.bbox = bbox
	if paint, has := resolve_paint(p, style.fill, style.color, bbox); has {
		shape.fill = Fill{paint, style.fill_opacity, style.fill_rule}
	}
	if style.stroke_width > 0 {
		if paint, has := resolve_paint(p, style.stroke, style.color, bbox); has {
			shape.stroke = Stroke {
				paint       = paint,
				opacity     = style.stroke_opacity,
				width       = style.stroke_width,
				miter_limit = style.miter_limit,
				cap         = style.line_cap,
				join        = style.line_join,
				dashes      = style.dashes,
				dash_offset = style.dash_offset,
			}
		}
	}
	if shape.fill == nil && shape.stroke == nil {return nil}
	shape_update_bounds(shape)
	return shape
}

// How far a stroke can reach past the geometry it outlines, in user units.
stroke_reach :: proc(s: Stroke) -> f64 {
	factor := 1.0
	if s.join == .Miter {factor = max(factor, s.miter_limit)}
	if s.cap == .Square {factor = max(factor, math.SQRT_TWO)}
	return s.width / 2 * factor
}

@(private = "file")
shape_update_bounds :: proc(shape: ^Shape) {
	shape.bounds = shape.bbox
	if s, has := shape.stroke.?; has {
		shape.bounds = rect_expand(shape.bbox, stroke_reach(s))
	}
}

@(private = "file")
resolve_paint :: proc(p: ^Parser, spec: Paint_Spec, current: Color, bbox: Rect) -> (paint: Paint, ok: bool) {
	switch spec.kind {
	case .None:
		return
	case .Color:
		return {kind = .Solid, color = spec.color}, true
	case .Current_Color:
		return {kind = .Solid, color = current}, true
	case .Url:
		if id, found := p.ids[spec.url]; found {
			tag := local_name(p.x.elements[id].ident)
			if g := resolve_gradient(p, id); g != nil {
				switch {
				case len(g.stops) == 0:
					return
				case len(g.stops) == 1:
					return {kind = .Solid, color = g.stops[0].color}, true
				case g.object_bbox_units && !(bbox.max.x > bbox.min.x && bbox.max.y > bbox.min.y):
					return
				case (!g.radial && g.start == g.end) || (g.radial && !(g.radius > 0)):
					return {kind = .Solid, color = g.stops[len(g.stops) - 1].color}, true
				}
				return {kind = .Gradient, gradient = g}, true
			} else if tag == "pattern" {
				note_unsupported(p, "pattern fill")
			}
		}
		if spec.has_fallback {
			fallback := Paint_Spec{kind = spec.fallback, color = spec.fallback_color}
			return resolve_paint(p, fallback, current, bbox)
		}
	}
	return
}

@(private = "file")
resolve_gradient :: proc(p: ^Parser, id: Element_ID) -> ^Gradient {
	if g, cached := p.gradients[id]; cached {return g}
	tag := local_name(p.x.elements[id].ident)
	if tag != "linearGradient" && tag != "radialGradient" {return nil}

	// The href chain, nearest first; attributes and stops come from the first
	// element in it that specifies them.
	chain: [dynamic]^Element
	for cur := id; len(chain) < 16; {
		el := &p.x.elements[cur]
		t := local_name(el.ident)
		if t != "linearGradient" && t != "radialGradient" {break}
		if slice.contains(chain[:], el) {break}
		append(&chain, el)
		cur = resolve_href(p, el) or_break
	}
	lookup :: proc(chain: []^Element, name: string) -> (string, bool) {
		for el in chain {
			if v, has := attr(el, name); has {return v, true}
		}
		return "", false
	}

	g := new(Gradient)
	g.radial = tag == "radialGradient"
	units, _ := lookup(chain[:], "gradientUnits")
	g.object_bbox_units = units != "userSpaceOnUse"
	g.transform = IDENTITY
	if t, has := lookup(chain[:], "gradientTransform"); has {
		g.transform = parse_transform(t) or_else IDENTITY
	}
	switch s, _ := lookup(chain[:], "spreadMethod"); s {
	case "reflect":
		g.spread = .Reflect
	case "repeat":
		g.spread = .Repeat
	}

	coord :: proc(p: ^Parser, g: ^Gradient, chain: []^Element, name, fallback: string, axis: Axis) -> f64 {
		s, has := lookup(chain, name)
		if !has {s = fallback}
		if g.object_bbox_units {
			v, pct, ok := parse_number_or_percent(trim(s))
			if !ok {v, pct, _ = parse_number_or_percent(fallback)}
			return pct ? v / 100 : v
		}
		v, ok := parse_length(s, axis, p.viewport)
		if !ok {v, _ = parse_length(fallback, axis, p.viewport)}
		return v
	}
	if g.radial {
		g.center = {coord(p, g, chain[:], "cx", "50%", .X), coord(p, g, chain[:], "cy", "50%", .Y)}
		g.radius = coord(p, g, chain[:], "r", "50%", .Other)
		g.focal = g.center
		if _, has := lookup(chain[:], "fx"); has {g.focal.x = coord(p, g, chain[:], "fx", "50%", .X)}
		if _, has := lookup(chain[:], "fy"); has {g.focal.y = coord(p, g, chain[:], "fy", "50%", .Y)}
		// SVG 1.1: a focal point outside the circle is moved onto it. Kept
		// just inside so the gradient equation stays well-conditioned.
		if d := g.focal - g.center; math.sqrt(d.x * d.x + d.y * d.y) > g.radius * 0.999 && g.radius > 0 {
			g.focal = g.center + d / math.sqrt(d.x * d.x + d.y * d.y) * g.radius * 0.999
		}
	} else {
		g.start = {coord(p, g, chain[:], "x1", "0%", .X), coord(p, g, chain[:], "y1", "0%", .Y)}
		g.end = {coord(p, g, chain[:], "x2", "100%", .X), coord(p, g, chain[:], "y2", "0%", .Y)}
	}

	stops: [dynamic]Stop
	base := default_style()
	for el in chain {
		for v in el.value {
			child, is_el := v.(Element_ID)
			if !is_el || local_name(p.x.elements[child].ident) != "stop" {continue}
			st := compute_style(p, child, &base)
			offset: f64
			if s, has := attr(&p.x.elements[child], "offset"); has {
				n, pct, ok := parse_number_or_percent(trim(s))
				if ok {offset = pct ? n / 100 : n}
			}
			offset = clamp(offset, 0, 1)
			if len(stops) > 0 {offset = max(offset, f64(stops[len(stops) - 1].offset))}
			c := st.stop_color
			c.a *= st.stop_opacity
			append(&stops, Stop{f32(offset), c})
		}
		if len(stops) > 0 {break}
	}
	g.stops = stops[:]
	p.gradients[id] = g
	return g
}

@(private = "file")
resolve_clip :: proc(p: ^Parser, ref: string) -> ^Clip_Path {
	if ref == "" {return nil}
	id, found := p.ids[ref]
	if !found {return nil}
	el := &p.x.elements[id]
	if local_name(el.ident) != "clipPath" {return nil}
	if c, seen := p.clips[id]; seen {return c}
	p.clips[id] = nil

	clip := new(Clip_Path)
	units, _ := attr(el, "clipPathUnits")
	clip.object_bbox_units = units == "objectBoundingBox"
	clip.transform = IDENTITY
	if t, has := attr(el, "transform"); has {
		clip.transform = parse_transform(t) or_else IDENTITY
	}
	base := default_style()
	cstyle := compute_style(p, id, &base)
	clip.clip = resolve_clip(p, cstyle.clip_path)

	for v in el.value {
		child, is_el := v.(Element_ID)
		if !is_el {continue}
		add_clip_item(p, clip, child, &cstyle, IDENTITY)
	}
	p.clips[id] = clip
	return clip
}

@(private = "file")
add_clip_item :: proc(p: ^Parser, clip: ^Clip_Path, id: Element_ID, parent: ^Style, outer: Transform) {
	el := &p.x.elements[id]
	tag := local_name(el.ident)
	st := compute_style(p, id, parent)
	if !st.displayed {return}
	ts := outer
	if t, has := attr(el, "transform"); has {
		ts = transform_mul(ts, parse_transform(t) or_else IDENTITY)
	}
	if tag == "text" {
		// Clip paths use glyph outlines as geometry, like any other shape.
		nodes: [dynamic]Node
		convert_text(p, id, &st, &nodes)
		for n in nodes {
			if shape, ok := n.(^Shape); ok {
				append(&clip.items, Clip_Item{transform = transform_mul(ts, shape.transform), path = shape.path, rule = st.clip_rule})
			}
		}
		return
	}
	if tag == "use" {
		target, ok := resolve_href(p, el)
		if !ok || len(p.use_stack) >= MAX_USE_DEPTH || slice.contains(p.use_stack[:], target) {return}
		ts = transform_mul(ts, translate(length_attr(p, el, "x", .X, 0), length_attr(p, el, "y", .Y, 0)))
		append(&p.use_stack, target)
		add_clip_item(p, clip, target, &st, ts)
		pop(&p.use_stack)
		return
	}
	if !st.visible {return}
	if path, ok := shape_path(p, el, tag); ok {
		append(&clip.items, Clip_Item{transform = ts, path = path, rule = st.clip_rule})
	}
}

@(private = "file")
parse_viewbox :: proc(el: ^Element) -> (vb: [4]f64, ok: bool) {
	s := attr(el, "viewBox") or_return
	nums := parse_number_list(s, context.temp_allocator)
	if len(nums) != 4 || !(nums[2] > 0 && nums[3] > 0) {return}
	return {nums[0], nums[1], nums[2], nums[3]}, true
}

@(private = "file")
Aspect_Ratio :: struct {
	align_x, align_y: f64, // 0, 0.5 or 1; ignored when `none`
	none:             bool,
	slice:            bool,
}

@(private = "file")
parse_aspect_ratio :: proc(el: ^Element) -> Aspect_Ratio {
	ar := Aspect_Ratio{align_x = 0.5, align_y = 0.5}
	s, has := attr(el, "preserveAspectRatio")
	if !has {return ar}
	rest := s
	for word in strings.fields_iterator(&rest) {
		switch word {
		case "none":
			ar.none = true
		case "slice":
			ar.slice = true
		case "meet", "defer":
		case:
			if len(word) == 8 && word[0] == 'x' && word[4] == 'Y' {
				pos :: proc(s: string) -> f64 {
					switch s {
					case "Min":
						return 0
					case "Max":
						return 1
					}
					return 0.5
				}
				ar.align_x = pos(word[1:4])
				ar.align_y = pos(word[5:8])
			}
		}
	}
	return ar
}

@(private = "file")
viewbox_transform :: proc(vb: [4]f64, ar: Aspect_Ratio, w, h: f64) -> Transform {
	sx := w / vb[2]
	sy := h / vb[3]
	if ar.none {
		return {sx, 0, 0, sy, -vb[0] * sx, -vb[1] * sy}
	}
	s := ar.slice ? max(sx, sy) : min(sx, sy)
	tx := -vb[0] * s + (w - vb[2] * s) * ar.align_x
	ty := -vb[1] * s + (h - vb[3] * s) * ar.align_y
	return {s, 0, 0, s, tx, ty}
}
