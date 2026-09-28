package svg

import "core:math"
import "core:strings"

@(private)
Paint_Spec_Kind :: enum u8 {
	None,
	Color,
	Current_Color,
	Url,
}

// A `fill`/`stroke` value as written, before references are resolved.
@(private)
Paint_Spec :: struct {
	kind:           Paint_Spec_Kind,
	color:          Color,
	url:            string, // id without the `#`
	// What to use if `url` doesn't resolve to a supported paint server.
	has_fallback:   bool,
	fallback:       Paint_Spec_Kind,
	fallback_color: Color,
}

// Computed presentation properties for one element.
@(private)
Style :: struct {
	// Inherited.
	fill:           Paint_Spec,
	fill_opacity:   f32,
	fill_rule:      Fill_Rule,
	stroke:         Paint_Spec,
	stroke_opacity: f32,
	stroke_width:   f64,
	line_cap:       Line_Cap,
	line_join:      Line_Join,
	miter_limit:    f64,
	dashes:         []f64,
	dash_offset:    f64,
	color:          Color,
	visible:        bool,
	clip_rule:      Fill_Rule,
	font_family:    string,
	font_size:      f64,
	font_weight:    int,
	italic:         bool,
	text_anchor:    Text_Anchor,
	letter_spacing: f64,
	word_spacing:   f64,
	// Not inherited.
	opacity:        f32,
	clip_path:      string,
	displayed:      bool,
	stop_color:     Color,
	stop_opacity:   f32,
	has_mask:       bool,
	has_filter:     bool,
}

@(private)
Text_Anchor :: enum u8 {
	Start,
	Middle,
	End,
}

@(private)
default_style :: proc() -> Style {
	return {
		fill = {kind = .Color, color = BLACK},
		fill_opacity = 1,
		stroke_opacity = 1,
		stroke_width = 1,
		miter_limit = 4,
		color = BLACK,
		visible = true,
		font_family = "sans-serif",
		font_size = 16,
		font_weight = 400,
		opacity = 1,
		displayed = true,
		stop_color = BLACK,
		stop_opacity = 1,
	}
}

// Cascades `id`'s style from `parent`: presentation attributes first, then
// matching stylesheet rules in specificity order, then the `style` attribute.
@(private)
compute_style :: proc(p: ^Parser, id: Element_ID, parent: ^Style) -> Style {
	s := parent^
	s.opacity = 1
	s.clip_path = ""
	s.displayed = true
	s.stop_color = BLACK
	s.stop_opacity = 1
	s.has_mask = false
	s.has_filter = false

	el := &p.x.elements[id]
	for a in el.attribs {
		apply_property(p, &s, parent, local_name(a.key), a.val)
	}
	if len(p.rules) > 0 {
		tag := local_name(el.ident)
		el_id, _ := attr(el, "id")
		class, _ := attr(el, "class")
		for rule in p.rules {
			if selector_matches(rule.selector, tag, el_id, class) {
				for d in rule.decls {
					apply_property(p, &s, parent, d.name, d.value)
				}
			}
		}
	}
	if style_attr, ok := attr(el, "style"); ok {
		decls: [dynamic]Declaration
		parse_declarations(style_attr, &decls)
		for d in decls {
			apply_property(p, &s, parent, d.name, d.value)
		}
	}
	return s
}

@(private = "file")
apply_property :: proc(p: ^Parser, s: ^Style, parent: ^Style, name, raw_value: string) {
	value := trim(raw_value)
	if value == "inherit" {
		inherit_property(s, parent, name)
		return
	}
	switch name {
	case "fill":
		if ps, ok := parse_paint(value); ok {s.fill = ps}
	case "stroke":
		if ps, ok := parse_paint(value); ok {s.stroke = ps}
	case "fill-opacity":
		if v, ok := parse_opacity(value); ok {s.fill_opacity = v}
	case "stroke-opacity":
		if v, ok := parse_opacity(value); ok {s.stroke_opacity = v}
	case "opacity":
		if v, ok := parse_opacity(value); ok {s.opacity = v}
	case "stop-opacity":
		if v, ok := parse_opacity(value); ok {s.stop_opacity = v}
	case "fill-rule":
		if v, ok := parse_fill_rule(value); ok {s.fill_rule = v}
	case "clip-rule":
		if v, ok := parse_fill_rule(value); ok {s.clip_rule = v}
	case "stroke-width":
		if v, ok := parse_length(value, .Other, p.viewport); ok && v >= 0 {s.stroke_width = v}
	case "stroke-linecap":
		switch value {
		case "butt":
			s.line_cap = .Butt
		case "round":
			s.line_cap = .Round
		case "square":
			s.line_cap = .Square
		}
	case "stroke-linejoin":
		switch value {
		case "miter", "miter-clip", "arcs":
			s.line_join = .Miter
		case "round":
			s.line_join = .Round
		case "bevel":
			s.line_join = .Bevel
		}
	case "stroke-miterlimit":
		sc := Scanner{s = value}
		if v, ok := scan_number(&sc); ok && v >= 1 {s.miter_limit = v}
	case "stroke-dasharray":
		s.dashes = parse_dasharray(value, p.viewport)
	case "stroke-dashoffset":
		if v, ok := parse_length(value, .Other, p.viewport); ok {s.dash_offset = v}
	case "color":
		if c, ok := parse_color(value); ok {s.color = c}
	case "stop-color":
		if value == "currentColor" {
			s.stop_color = s.color
		} else if c, ok := parse_color(value); ok {
			s.stop_color = c
		}
	case "visibility":
		s.visible = value == "visible"
	case "display":
		s.displayed = value != "none"
	case "clip-path":
		s.clip_path = parse_url(value) or_else ""
	case "font-family":
		s.font_family = value
	case "font-size":
		if v, ok := parse_font_size(value, parent.font_size, p.viewport); ok {s.font_size = v}
	case "font-weight":
		switch value {
		case "normal":
			s.font_weight = 400
		case "bold":
			s.font_weight = 700
		case "bolder":
			s.font_weight = min(parent.font_weight + 300, 900)
		case "lighter":
			s.font_weight = max(parent.font_weight - 300, 100)
		case:
			sc := Scanner{s = value}
			if v, ok := scan_number(&sc); ok && sc.i == len(value) && v >= 1 && v <= 1000 {s.font_weight = int(v)}
		}
	case "font-style":
		s.italic = value == "italic" || strings.has_prefix(value, "oblique")
	case "text-anchor":
		switch value {
		case "start":
			s.text_anchor = .Start
		case "middle":
			s.text_anchor = .Middle
		case "end":
			s.text_anchor = .End
		}
	case "letter-spacing":
		if value == "normal" {
			s.letter_spacing = 0
		} else if v, ok := parse_length(value, .Other, p.viewport); ok {
			s.letter_spacing = v
		}
	case "word-spacing":
		if value == "normal" {
			s.word_spacing = 0
		} else if v, ok := parse_length(value, .Other, p.viewport); ok {
			s.word_spacing = v
		}
	case "mask":
		s.has_mask = value != "none"
	case "filter":
		s.has_filter = value != "none"
	}
}

@(private = "file")
inherit_property :: proc(s: ^Style, parent: ^Style, name: string) {
	switch name {
	case "fill":
		s.fill = parent.fill
	case "stroke":
		s.stroke = parent.stroke
	case "fill-opacity":
		s.fill_opacity = parent.fill_opacity
	case "stroke-opacity":
		s.stroke_opacity = parent.stroke_opacity
	case "opacity":
		s.opacity = parent.opacity
	case "fill-rule":
		s.fill_rule = parent.fill_rule
	case "clip-rule":
		s.clip_rule = parent.clip_rule
	case "stroke-width":
		s.stroke_width = parent.stroke_width
	case "stroke-linecap":
		s.line_cap = parent.line_cap
	case "stroke-linejoin":
		s.line_join = parent.line_join
	case "stroke-miterlimit":
		s.miter_limit = parent.miter_limit
	case "stroke-dasharray":
		s.dashes = parent.dashes
	case "stroke-dashoffset":
		s.dash_offset = parent.dash_offset
	case "color":
		s.color = parent.color
	case "visibility":
		s.visible = parent.visible
	case "clip-path":
		s.clip_path = parent.clip_path
	case "font-family":
		s.font_family = parent.font_family
	case "font-size":
		s.font_size = parent.font_size
	case "font-weight":
		s.font_weight = parent.font_weight
	case "font-style":
		s.italic = parent.italic
	case "text-anchor":
		s.text_anchor = parent.text_anchor
	case "letter-spacing":
		s.letter_spacing = parent.letter_spacing
	case "word-spacing":
		s.word_spacing = parent.word_spacing
	}
}

@(private = "file")
parse_font_size :: proc(value: string, parent_size: f64, viewport: Vec2) -> (v: f64, ok: bool) {
	switch value {
	case "xx-small":
		return 9, true
	case "x-small":
		return 10, true
	case "small":
		return 13, true
	case "medium":
		return 16, true
	case "large":
		return 18, true
	case "x-large":
		return 24, true
	case "xx-large":
		return 32, true
	case "larger":
		return parent_size * 1.2, true
	case "smaller":
		return parent_size / 1.2, true
	}
	sc := Scanner{s = value}
	n := scan_number(&sc) or_return
	switch trim(value[sc.i:]) {
	case "em":
		v = n * parent_size
	case "%":
		v = n * parent_size / 100
	case "ex":
		v = n * parent_size / 2
	case:
		v = parse_length(value, .Other, viewport) or_return
	}
	return v, v >= 0
}

@(private = "file")
parse_paint :: proc(value: string) -> (ps: Paint_Spec, ok: bool) {
	simple :: proc(v: string) -> (kind: Paint_Spec_Kind, color: Color, ok: bool) {
		switch v {
		case "none", "context-fill", "context-stroke":
			return .None, {}, true
		case "currentColor":
			return .Current_Color, {}, true
		}
		c := parse_color(v) or_return
		return .Color, c, true
	}
	if strings.has_prefix(value, "url(") {
		close := strings.index_byte(value, ')')
		if close < 0 {return}
		ps.kind = .Url
		ps.url = parse_url(value[:close + 1]) or_return
		if rest := trim(value[close + 1:]); rest != "" {
			ps.fallback, ps.fallback_color = simple(rest) or_return
			ps.has_fallback = true
		}
		return ps, true
	}
	ps.kind, ps.color = simple(value) or_return
	return ps, true
}

// `url(#id)` / `url('#id')` -> `id`.
@(private)
parse_url :: proc(value: string) -> (id: string, ok: bool) {
	v := trim(value)
	if !strings.has_prefix(v, "url(") || !strings.has_suffix(v, ")") {return}
	v = trim(v[4:len(v) - 1])
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v) - 1] == v[0] {
		v = v[1:len(v) - 1]
	}
	if !strings.has_prefix(v, "#") {return}
	return v[1:], true
}

@(private = "file")
parse_opacity :: proc(value: string) -> (v: f32, ok: bool) {
	n, pct := parse_number_or_percent(value) or_return
	return f32(clamp(pct ? n / 100 : n, 0, 1)), true
}

@(private = "file")
parse_fill_rule :: proc(value: string) -> (r: Fill_Rule, ok: bool) {
	switch value {
	case "nonzero":
		return .Non_Zero, true
	case "evenodd":
		return .Even_Odd, true
	}
	return
}

@(private = "file")
parse_dasharray :: proc(value: string, viewport: Vec2) -> []f64 {
	if value == "none" {return nil}
	out: [dynamic]f64
	rest := value
	sum := 0.0
	for {
		rest = strings.trim_left(rest, " \t\n\r,")
		if rest == "" {break}
		end := strings.index_any(rest, " \t\n\r,")
		if end < 0 {end = len(rest)}
		v, ok := parse_length(rest[:end], .Other, viewport)
		if !ok || v < 0 {return nil}
		append(&out, v)
		sum += v
		rest = rest[end:]
	}
	if sum <= 0 {return nil}
	if len(out) % 2 == 1 {
		n := len(out)
		for i in 0 ..< n {append(&out, out[i])}
	}
	return out[:]
}

@(private)
Axis :: enum u8 {
	X,
	Y,
	Other, // percentages resolve against the normalized viewport diagonal
}

// Parses a length with an optional unit into user units (px), resolving
// percentages against `viewport`.
@(private)
parse_length :: proc(value: string, axis: Axis, viewport: Vec2) -> (v: f64, ok: bool) {
	sc := Scanner{s = value}
	n := scan_number(&sc) or_return
	unit := trim(value[sc.i:])
	switch unit {
	case "", "px":
		return n, true
	case "%":
		ref: f64
		switch axis {
		case .X:
			ref = viewport.x
		case .Y:
			ref = viewport.y
		case .Other:
			ref = math.sqrt((viewport.x * viewport.x + viewport.y * viewport.y) / 2)
		}
		return n * ref / 100, true
	case "pt":
		return n * 4 / 3, true
	case "pc":
		return n * 16, true
	case "mm":
		return n * 96 / 25.4, true
	case "cm":
		return n * 96 / 2.54, true
	case "in":
		return n * 96, true
	case "em":
		return n * 16, true // no font support, so the initial 16px font size
	case "ex":
		return n * 8, true
	}
	return 0, false
}
