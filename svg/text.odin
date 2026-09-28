package svg

import "core:unicode/utf8"

// Text is converted to glyph-outline shapes at load time, so it renders
// (and clips) like any other geometry. Layout is simple: one font per span,
// no shaping, kerning or bidi; `x`/`y`/`dx`/`dy` lists, `text-anchor`,
// `letter-spacing` and `word-spacing` are honored.

@(private = "file")
Text_Char :: struct {
	r:        rune,
	style:    int, // index into Text_Layout.styles
	x, y:     Maybe(f64), // absolute position, starting a new chunk
	dx, dy:   f64,
	pos:      Vec2, // laid-out pen position
	glyph:    int,
	advance:  f64,
}

@(private = "file")
Text_Layout :: struct {
	chars:    [dynamic]Text_Char,
	styles:   [dynamic]Style,
	fonts:    [dynamic]^Font,
	preserve: bool, // xml:space="preserve"
}

@(private)
convert_text :: proc(p: ^Parser, id: Element_ID, style: ^Style, out: ^[dynamic]Node) {
	tl: Text_Layout
	space, _ := attr(&p.x.elements[id], "space")
	tl.preserve = space == "preserve"
	collect_text(p, &tl, id, style)
	// Trailing whitespace is dropped (leading is never emitted).
	if !tl.preserve && len(tl.chars) > 0 && tl.chars[len(tl.chars) - 1].r == ' ' {
		pop(&tl.chars)
	}
	if len(tl.chars) == 0 {return}

	for &st in tl.styles {
		append(&tl.fonts, match_font(st.font_family, st.font_weight, st.italic))
	}
	if tl.fonts[0] == nil {
		note_unsupported(p, "<text> (no usable fonts found)")
		return
	}

	// Pen positions, split into chunks at each absolute x/y.
	pen: Vec2
	chunk_start := 0
	for &c, i in tl.chars {
		x, has_x := c.x.?
		y, has_y := c.y.?
		if (has_x || has_y) && i > 0 {
			anchor_chunk(&tl, chunk_start, i, pen.x)
			chunk_start = i
		}
		if has_x {pen.x = x}
		if has_y {pen.y = y}
		pen += {c.dx, c.dy}
		c.pos = pen

		st := &tl.styles[c.style]
		f := tl.fonts[c.style]
		if f == nil {continue}
		c.glyph = font_glyph_index(f, c.r)
		c.advance = font_advance(f, c.glyph) * st.font_size / f.units_per_em
		pen.x += c.advance + st.letter_spacing
		if c.r == ' ' {pen.x += st.word_spacing}
	}
	anchor_chunk(&tl, chunk_start, len(tl.chars), pen.x)

	// One shape per run of characters sharing a style.
	for start := 0; start < len(tl.chars); {
		end := start + 1
		for end < len(tl.chars) && tl.chars[end].style == tl.chars[start].style {end += 1}
		st := &tl.styles[tl.chars[start].style]
		f := tl.fonts[tl.chars[start].style]
		if f != nil && st.visible {
			path: Path
			s := st.font_size / f.units_per_em
			for c in tl.chars[start:end] {
				// Font units are y-up; SVG is y-down.
				font_outline(f, c.glyph, Transform{s, 0, 0, -s, c.pos.x, c.pos.y}, &path)
			}
			if path_has_segments(path) {
				if shape := make_shape(p, path, st); shape != nil {
					append(out, Node(shape))
				}
			}
		}
		start = end
	}
}

// Shifts chars[start:end] for the chunk's text-anchor, given where the pen
// ended up.
@(private = "file")
anchor_chunk :: proc(tl: ^Text_Layout, start, end: int, pen_x: f64) {
	if start >= end {return}
	anchor := tl.styles[tl.chars[start].style].text_anchor
	if anchor == .Start {return}
	width := pen_x - tl.chars[start].pos.x
	shift := anchor == .Middle ? -width / 2 : -width
	for &c in tl.chars[start:end] {
		c.pos.x += shift
	}
}

@(private = "file")
collect_text :: proc(p: ^Parser, tl: ^Text_Layout, id: Element_ID, style: ^Style) {
	el := &p.x.elements[id]
	append(&tl.styles, style^)
	style_idx := len(tl.styles) - 1
	first := len(tl.chars)

	for v in el.value {
		switch child in v {
		case string:
			add_text(tl, child, style_idx)
		case Element_ID:
			cel := &p.x.elements[child]
			switch local_name(cel.ident) {
			case "tspan", "a":
				cst := compute_style(p, child, style)
				if cst.displayed {collect_text(p, tl, child, &cst)}
			case "textPath":
				note_unsupported(p, "<textPath>")
			}
		}
	}

	// Per-character positions from this element's lists; characters already
	// positioned by a nested element keep their own.
	chars := tl.chars[first:]
	lists := [4]string{"x", "y", "dx", "dy"}
	for name, k in lists {
		s, has := attr(el, name)
		if !has {continue}
		axis: Axis = k % 2 == 0 ? .X : .Y
		i := 0
		rest := s
		for i < len(chars) {
			rest = trim_list_separators(rest)
			if rest == "" {break}
			end := 0
			for end < len(rest) && !is_space(rest[end]) && rest[end] != ',' {end += 1}
			v, ok := parse_length(rest[:end], axis, p.viewport)
			rest = rest[end:]
			if !ok {break}
			c := &chars[i]
			switch k {
			case 0:
				if c.x == nil {c.x = v}
			case 1:
				if c.y == nil {c.y = v}
			case 2:
				c.dx += v
			case 3:
				c.dy += v
			}
			i += 1
		}
	}
}

@(private = "file")
trim_list_separators :: proc(s: string) -> string {
	i := 0
	for i < len(s) && (is_space(s[i]) || s[i] == ',') {i += 1}
	return s[i:]
}

// Appends text with SVG 1.1 whitespace handling: newlines are removed,
// tabs become spaces, and (unless preserving) runs of spaces collapse and
// leading ones are dropped.
@(private = "file")
add_text :: proc(tl: ^Text_Layout, s: string, style_idx: int) {
	for r in s {
		c := r
		switch c {
		case '\n', '\r':
			if !tl.preserve {continue}
			c = ' '
		case '\t':
			c = ' '
		}
		if c == ' ' && !tl.preserve {
			if len(tl.chars) == 0 || tl.chars[len(tl.chars) - 1].r == ' ' {continue}
		}
		if c == utf8.RUNE_ERROR {continue}
		append(&tl.chars, Text_Char{r = c, style = style_idx})
	}
}
