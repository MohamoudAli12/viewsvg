package svg

import "core:strconv"
import "core:strings"

// Cursor over the number lists found in path data, transforms, points,
// viewBoxes and dash arrays.
@(private)
Scanner :: struct {
	s: string,
	i: int,
}

@(private)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

@(private)
skip_space :: proc(sc: ^Scanner) {
	for sc.i < len(sc.s) && is_space(sc.s[sc.i]) {
		sc.i += 1
	}
}

// Skips whitespace and at most one comma.
@(private)
skip_separator :: proc(sc: ^Scanner) {
	skip_space(sc)
	if sc.i < len(sc.s) && sc.s[sc.i] == ',' {
		sc.i += 1
		skip_space(sc)
	}
}

@(private)
at_end :: proc(sc: ^Scanner) -> bool {
	return sc.i >= len(sc.s)
}

@(private)
peek :: proc(sc: ^Scanner) -> u8 {
	return sc.i < len(sc.s) ? sc.s[sc.i] : 0
}

// Scans an SVG number (`-1.5e3`, `.5`, `+2.`) at the cursor. Scanning the
// extent by hand rather than letting strconv find it matters for inputs like
// `1.5.5` (two numbers) and `2e` (a number then garbage), and keeps words
// like `inf` from being accepted as numbers.
@(private)
scan_number :: proc(sc: ^Scanner) -> (value: f64, ok: bool) {
	skip_space(sc)
	s := sc.s
	start := sc.i
	i := start
	if i < len(s) && (s[i] == '+' || s[i] == '-') {i += 1}
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
		digits += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
			digits += 1
		}
	}
	if digits == 0 {return 0, false}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {j += 1}
		if j < len(s) && s[j] >= '0' && s[j] <= '9' {
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {j += 1}
			i = j
		}
	}
	value, ok = strconv.parse_f64(s[start:i])
	if !ok || !is_finite(value) {return 0, false}
	sc.i = i
	return value, true
}

// Parses a whitespace/comma-separated list of numbers. Stops at the first
// thing that isn't a number.
@(private)
parse_number_list :: proc(s: string, allocator := context.allocator) -> [dynamic]f64 {
	out := make([dynamic]f64, allocator)
	sc := Scanner{s = s}
	for {
		skip_separator(&sc)
		if at_end(&sc) {break}
		v, ok := scan_number(&sc)
		if !ok {break}
		append(&out, v)
	}
	return out
}

@(private)
trim :: proc(s: string) -> string {
	return strings.trim_space(s)
}
