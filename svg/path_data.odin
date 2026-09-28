package svg

// Parses SVG path data (the `d` attribute) into `out`. Relative commands are
// made absolute and quadratics/arcs become cubics. As the spec requires, a
// syntax error keeps everything parsed before it rather than dropping the path.
parse_path_data :: proc(d: string, out: ^Path) {
	sc := Scanner{s = d}
	cur, start: Vec2
	// Reflection sources for S/T: the previous command's last control point.
	last_cubic_ctrl, last_quad_ctrl: Vec2
	prev: u8 = 0
	cmd: u8 = 0
	// After a Z, drawing continues from the subpath start without an M.
	need_move := false

	for {
		skip_separator(&sc)
		if at_end(&sc) {break}

		c := peek(&sc)
		if is_command(c) {
			cmd = c
			sc.i += 1
		} else if cmd == 0 {
			return // data must start with a command
		} else if cmd == 'M' {
			cmd = 'L' // numbers after a moveto are implicit linetos
		} else if cmd == 'm' {
			cmd = 'l'
		} else if cmd == 'Z' || cmd == 'z' {
			return
		}

		rel := cmd >= 'a'
		base := rel ? cur : Vec2{}
		upper := rel ? cmd - 32 : cmd

		if upper != 'M' && upper != 'Z' && need_move {
			path_move_to(out, cur)
			need_move = false
		}

		switch upper {
		case 'Z':
			path_close(out)
			cur = start
			need_move = true
		case 'M':
			p, ok := scan_point(&sc)
			if !ok {return}
			cur = base + p
			start = cur
			path_move_to(out, cur)
			need_move = false
		case 'L':
			p, ok := scan_point(&sc)
			if !ok {return}
			cur = base + p
			path_line_to(out, cur)
		case 'H':
			x, ok := scan_number(&sc)
			if !ok {return}
			cur.x = (rel ? cur.x : 0) + x
			path_line_to(out, cur)
		case 'V':
			y, ok := scan_number(&sc)
			if !ok {return}
			cur.y = (rel ? cur.y : 0) + y
			path_line_to(out, cur)
		case 'C':
			c1, ok1 := scan_point(&sc)
			c2, ok2 := scan_point(&sc)
			p, ok3 := scan_point(&sc)
			if !(ok1 && ok2 && ok3) {return}
			last_cubic_ctrl = base + c2
			cur = base + p
			path_cubic_to(out, base + c1, last_cubic_ctrl, cur)
		case 'S':
			c2, ok1 := scan_point(&sc)
			p, ok2 := scan_point(&sc)
			if !(ok1 && ok2) {return}
			c1 := cur
			if prev == 'C' || prev == 'S' {c1 = 2 * cur - last_cubic_ctrl}
			last_cubic_ctrl = base + c2
			cur = base + p
			path_cubic_to(out, c1, last_cubic_ctrl, cur)
		case 'Q':
			q, ok1 := scan_point(&sc)
			p, ok2 := scan_point(&sc)
			if !(ok1 && ok2) {return}
			last_quad_ctrl = base + q
			end := base + p
			quad_to(out, cur, last_quad_ctrl, end)
			cur = end
		case 'T':
			p, ok := scan_point(&sc)
			if !ok {return}
			q := cur
			if prev == 'Q' || prev == 'T' {q = 2 * cur - last_quad_ctrl}
			last_quad_ctrl = q
			end := base + p
			quad_to(out, cur, q, end)
			cur = end
		case 'A':
			rx, ok1 := scan_number(&sc)
			skip_separator(&sc)
			ry, ok2 := scan_number(&sc)
			skip_separator(&sc)
			rot, ok3 := scan_number(&sc)
			skip_separator(&sc)
			large, ok4 := scan_flag(&sc)
			skip_separator(&sc)
			sweep, ok5 := scan_flag(&sc)
			p, ok6 := scan_point(&sc)
			if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) {return}
			end := base + p
			path_arc_to(out, cur, rx, ry, rot, large, sweep, end)
			cur = end
		case:
			return
		}
		prev = upper
	}
}

@(private = "file")
is_command :: proc(c: u8) -> bool {
	switch c {
	case 'M', 'm', 'Z', 'z', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a':
		return true
	}
	return false
}

@(private = "file")
scan_point :: proc(sc: ^Scanner) -> (p: Vec2, ok: bool) {
	skip_separator(sc)
	p.x = scan_number(sc) or_return
	skip_separator(sc)
	p.y = scan_number(sc) or_return
	return p, true
}

// Arc flags are single characters and may be packed with no separator, as
// in `a1 1 0 01 5 5`.
@(private = "file")
scan_flag :: proc(sc: ^Scanner) -> (flag: bool, ok: bool) {
	skip_space(sc)
	switch peek(sc) {
	case '0':
		sc.i += 1
		return false, true
	case '1':
		sc.i += 1
		return true, true
	}
	return false, false
}

@(private = "file")
quad_to :: proc(out: ^Path, p0, q, p1: Vec2) {
	path_cubic_to(out, p0 + (q - p0) * (2.0 / 3.0), p1 + (q - p1) * (2.0 / 3.0), p1)
}

// Parses a `transform` attribute. Returns false (and identity) on a syntax
// error, which per spec disables the whole attribute.
parse_transform :: proc(s: string) -> (t: Transform, ok: bool) {
	t = IDENTITY
	sc := Scanner{s = s}
	for {
		skip_separator(&sc)
		if at_end(&sc) {break}
		name_start := sc.i
		for sc.i < len(sc.s) && ((sc.s[sc.i] >= 'a' && sc.s[sc.i] <= 'z') || (sc.s[sc.i] >= 'A' && sc.s[sc.i] <= 'Z')) {
			sc.i += 1
		}
		name := sc.s[name_start:sc.i]
		skip_space(&sc)
		if peek(&sc) != '(' {return IDENTITY, false}
		sc.i += 1

		args: [6]f64
		n := 0
		for {
			skip_separator(&sc)
			if peek(&sc) == ')' {
				sc.i += 1
				break
			}
			if n == 6 {return IDENTITY, false}
			v, vok := scan_number(&sc)
			if !vok {return IDENTITY, false}
			args[n] = v
			n += 1
		}

		m: Transform
		switch {
		case name == "matrix" && n == 6:
			m = {args[0], args[1], args[2], args[3], args[4], args[5]}
		case name == "translate" && (n == 1 || n == 2):
			m = translate(args[0], n == 2 ? args[1] : 0)
		case name == "scale" && (n == 1 || n == 2):
			m = scale(args[0], n == 2 ? args[1] : args[0])
		case name == "rotate" && n == 1:
			m = rotate(args[0])
		case name == "rotate" && n == 3:
			m = transform_mul(translate(args[1], args[2]), transform_mul(rotate(args[0]), translate(-args[1], -args[2])))
		case name == "skewX" && n == 1:
			m = {1, 0, math_tan_deg(args[0]), 1, 0, 0}
		case name == "skewY" && n == 1:
			m = {1, math_tan_deg(args[0]), 0, 1, 0, 0}
		case:
			return IDENTITY, false
		}
		t = transform_mul(t, m)
	}
	return t, true
}
