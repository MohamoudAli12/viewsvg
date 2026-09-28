package svg

import "core:math"
import "core:strings"

// Straight (non-premultiplied) RGBA, each channel in [0, 1].
Color :: [4]f32

BLACK :: Color{0, 0, 0, 1}

// Parses a CSS color: named colors, `transparent`, `#rgb`, `#rgba`,
// `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()` and `hsl()`/`hsla()` in both
// comma and space-separated forms.
parse_color :: proc(input: string) -> (c: Color, ok: bool) {
	s := trim(input)
	if len(s) == 0 {return}

	if s[0] == '#' {
		return parse_hex(s[1:])
	}

	buf: [32]u8
	if len(s) <= len(buf) {
		lower := lower_ascii(s, buf[:])
		if lower == "transparent" {return {0, 0, 0, 0}, true}
		if rgb, found := named_color(lower); found {
			return {f32((rgb >> 16) & 0xff) / 255, f32((rgb >> 8) & 0xff) / 255, f32(rgb & 0xff) / 255, 1}, true
		}
	}

	open := strings.index_byte(s, '(')
	if open < 0 || s[len(s) - 1] != ')' {return}
	fbuf: [16]u8
	fname := trim(s[:open])
	if len(fname) > len(fbuf) {return}
	fname = lower_ascii(fname, fbuf[:])
	args, n, args_ok := split_color_args(s[open + 1:len(s) - 1])
	if !args_ok {return}

	switch fname {
	case "rgb", "rgba":
		if n != 3 && n != 4 {return}
		for i in 0 ..< 3 {
			v, pct, vok := parse_number_or_percent(args[i])
			if !vok {return}
			c[i] = f32(clamp(pct ? v / 100 : v / 255, 0, 1))
		}
	case "hsl", "hsla":
		if n != 3 && n != 4 {return}
		h, hok := parse_hue(args[0])
		// CSS Color 4 allows bare numbers here, meaning percentages.
		sat, _, sok := parse_number_or_percent(args[1])
		light, _, lok := parse_number_or_percent(args[2])
		if !(hok && sok && lok) {return}
		c.rgb = hsl_to_rgb(h, clamp(sat / 100, 0, 1), clamp(light / 100, 0, 1))
	case:
		return
	}

	c.a = 1
	if n == 4 {
		a, pct, aok := parse_number_or_percent(args[3])
		if !aok {return}
		c.a = f32(clamp(pct ? a / 100 : a, 0, 1))
	}
	return c, true
}

@(private = "file")
parse_hex :: proc(h: string) -> (c: Color, ok: bool) {
	digit :: proc(ch: u8) -> (v: u32, ok: bool) {
		switch ch {
		case '0' ..= '9':
			return u32(ch - '0'), true
		case 'a' ..= 'f':
			return u32(ch - 'a' + 10), true
		case 'A' ..= 'F':
			return u32(ch - 'A' + 10), true
		}
		return 0, false
	}
	vals: [8]u32
	for i in 0 ..< len(h) {
		if i >= 8 {return}
		vals[i] = digit(h[i]) or_return
	}
	switch len(h) {
	case 3, 4:
		for i in 0 ..< len(h) {
			c[i] = f32(vals[i] * 17) / 255
		}
		if len(h) == 3 {c.a = 1}
	case 6, 8:
		for i in 0 ..< len(h) / 2 {
			c[i] = f32(vals[2 * i] * 16 + vals[2 * i + 1]) / 255
		}
		if len(h) == 6 {c.a = 1}
	case:
		return
	}
	return c, true
}

// Splits `a, b, c` / `a b c` / `a b c / d` into at most four arguments.
@(private = "file")
split_color_args :: proc(s: string) -> (args: [4]string, n: int, ok: bool) {
	i := 0
	for {
		for i < len(s) && (is_space(s[i]) || s[i] == ',' || s[i] == '/') {
			i += 1
		}
		if i >= len(s) {break}
		start := i
		for i < len(s) && !(is_space(s[i]) || s[i] == ',' || s[i] == '/') {
			i += 1
		}
		if n == 4 {return args, n, false}
		args[n] = s[start:i]
		n += 1
	}
	return args, n, true
}

@(private)
parse_number_or_percent :: proc(s: string) -> (v: f64, percent: bool, ok: bool) {
	sc := Scanner{s = s}
	v = scan_number(&sc) or_return
	rest := s[sc.i:]
	switch rest {
	case "":
		return v, false, true
	case "%":
		return v, true, true
	}
	return 0, false, false
}

@(private = "file")
parse_hue :: proc(s: string) -> (degrees: f64, ok: bool) {
	sc := Scanner{s = s}
	v := scan_number(&sc) or_return
	switch s[sc.i:] {
	case "", "deg":
		return v, true
	case "rad":
		return math.to_degrees(v), true
	case "grad":
		return v * 0.9, true
	case "turn":
		return v * 360, true
	}
	return 0, false
}

@(private = "file")
hsl_to_rgb :: proc(hue, s, l: f64) -> [3]f32 {
	h := math.mod(hue, 360)
	if h < 0 {h += 360}
	f :: proc(n, h, s, l: f64) -> f32 {
		k := math.mod(n + h / 30, 12)
		a := s * min(l, 1 - l)
		return f32(l - a * max(-1, min(k - 3, 9 - k, 1)))
	}
	return {f(0, h, s, l), f(8, h, s, l), f(4, h, s, l)}
}

@(private)
lower_ascii :: proc(s: string, buf: []u8) -> string {
	for i in 0 ..< len(s) {
		ch := s[i]
		buf[i] = ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	}
	return string(buf[:len(s)])
}

@(private = "file")
named_color :: proc(name: string) -> (rgb: u32, ok: bool) {
	switch name {
	case "aliceblue": return 0xf0f8ff, true
	case "antiquewhite": return 0xfaebd7, true
	case "aqua": return 0x00ffff, true
	case "aquamarine": return 0x7fffd4, true
	case "azure": return 0xf0ffff, true
	case "beige": return 0xf5f5dc, true
	case "bisque": return 0xffe4c4, true
	case "black": return 0x000000, true
	case "blanchedalmond": return 0xffebcd, true
	case "blue": return 0x0000ff, true
	case "blueviolet": return 0x8a2be2, true
	case "brown": return 0xa52a2a, true
	case "burlywood": return 0xdeb887, true
	case "cadetblue": return 0x5f9ea0, true
	case "chartreuse": return 0x7fff00, true
	case "chocolate": return 0xd2691e, true
	case "coral": return 0xff7f50, true
	case "cornflowerblue": return 0x6495ed, true
	case "cornsilk": return 0xfff8dc, true
	case "crimson": return 0xdc143c, true
	case "cyan": return 0x00ffff, true
	case "darkblue": return 0x00008b, true
	case "darkcyan": return 0x008b8b, true
	case "darkgoldenrod": return 0xb8860b, true
	case "darkgray", "darkgrey": return 0xa9a9a9, true
	case "darkgreen": return 0x006400, true
	case "darkkhaki": return 0xbdb76b, true
	case "darkmagenta": return 0x8b008b, true
	case "darkolivegreen": return 0x556b2f, true
	case "darkorange": return 0xff8c00, true
	case "darkorchid": return 0x9932cc, true
	case "darkred": return 0x8b0000, true
	case "darksalmon": return 0xe9967a, true
	case "darkseagreen": return 0x8fbc8f, true
	case "darkslateblue": return 0x483d8b, true
	case "darkslategray", "darkslategrey": return 0x2f4f4f, true
	case "darkturquoise": return 0x00ced1, true
	case "darkviolet": return 0x9400d3, true
	case "deeppink": return 0xff1493, true
	case "deepskyblue": return 0x00bfff, true
	case "dimgray", "dimgrey": return 0x696969, true
	case "dodgerblue": return 0x1e90ff, true
	case "firebrick": return 0xb22222, true
	case "floralwhite": return 0xfffaf0, true
	case "forestgreen": return 0x228b22, true
	case "fuchsia": return 0xff00ff, true
	case "gainsboro": return 0xdcdcdc, true
	case "ghostwhite": return 0xf8f8ff, true
	case "gold": return 0xffd700, true
	case "goldenrod": return 0xdaa520, true
	case "gray", "grey": return 0x808080, true
	case "green": return 0x008000, true
	case "greenyellow": return 0xadff2f, true
	case "honeydew": return 0xf0fff0, true
	case "hotpink": return 0xff69b4, true
	case "indianred": return 0xcd5c5c, true
	case "indigo": return 0x4b0082, true
	case "ivory": return 0xfffff0, true
	case "khaki": return 0xf0e68c, true
	case "lavender": return 0xe6e6fa, true
	case "lavenderblush": return 0xfff0f5, true
	case "lawngreen": return 0x7cfc00, true
	case "lemonchiffon": return 0xfffacd, true
	case "lightblue": return 0xadd8e6, true
	case "lightcoral": return 0xf08080, true
	case "lightcyan": return 0xe0ffff, true
	case "lightgoldenrodyellow": return 0xfafad2, true
	case "lightgray", "lightgrey": return 0xd3d3d3, true
	case "lightgreen": return 0x90ee90, true
	case "lightpink": return 0xffb6c1, true
	case "lightsalmon": return 0xffa07a, true
	case "lightseagreen": return 0x20b2aa, true
	case "lightskyblue": return 0x87cefa, true
	case "lightslategray", "lightslategrey": return 0x778899, true
	case "lightsteelblue": return 0xb0c4de, true
	case "lightyellow": return 0xffffe0, true
	case "lime": return 0x00ff00, true
	case "limegreen": return 0x32cd32, true
	case "linen": return 0xfaf0e6, true
	case "magenta": return 0xff00ff, true
	case "maroon": return 0x800000, true
	case "mediumaquamarine": return 0x66cdaa, true
	case "mediumblue": return 0x0000cd, true
	case "mediumorchid": return 0xba55d3, true
	case "mediumpurple": return 0x9370db, true
	case "mediumseagreen": return 0x3cb371, true
	case "mediumslateblue": return 0x7b68ee, true
	case "mediumspringgreen": return 0x00fa9a, true
	case "mediumturquoise": return 0x48d1cc, true
	case "mediumvioletred": return 0xc71585, true
	case "midnightblue": return 0x191970, true
	case "mintcream": return 0xf5fffa, true
	case "mistyrose": return 0xffe4e1, true
	case "moccasin": return 0xffe4b5, true
	case "navajowhite": return 0xffdead, true
	case "navy": return 0x000080, true
	case "oldlace": return 0xfdf5e6, true
	case "olive": return 0x808000, true
	case "olivedrab": return 0x6b8e23, true
	case "orange": return 0xffa500, true
	case "orangered": return 0xff4500, true
	case "orchid": return 0xda70d6, true
	case "palegoldenrod": return 0xeee8aa, true
	case "palegreen": return 0x98fb98, true
	case "paleturquoise": return 0xafeeee, true
	case "palevioletred": return 0xdb7093, true
	case "papayawhip": return 0xffefd5, true
	case "peachpuff": return 0xffdab9, true
	case "peru": return 0xcd853f, true
	case "pink": return 0xffc0cb, true
	case "plum": return 0xdda0dd, true
	case "powderblue": return 0xb0e0e6, true
	case "purple": return 0x800080, true
	case "rebeccapurple": return 0x663399, true
	case "red": return 0xff0000, true
	case "rosybrown": return 0xbc8f8f, true
	case "royalblue": return 0x4169e1, true
	case "saddlebrown": return 0x8b4513, true
	case "salmon": return 0xfa8072, true
	case "sandybrown": return 0xf4a460, true
	case "seagreen": return 0x2e8b57, true
	case "seashell": return 0xfff5ee, true
	case "sienna": return 0xa0522d, true
	case "silver": return 0xc0c0c0, true
	case "skyblue": return 0x87ceeb, true
	case "slateblue": return 0x6a5acd, true
	case "slategray", "slategrey": return 0x708090, true
	case "snow": return 0xfffafa, true
	case "springgreen": return 0x00ff7f, true
	case "steelblue": return 0x4682b4, true
	case "tan": return 0xd2b48c, true
	case "teal": return 0x008080, true
	case "thistle": return 0xd8bfd8, true
	case "tomato": return 0xff6347, true
	case "turquoise": return 0x40e0d0, true
	case "violet": return 0xee82ee, true
	case "wheat": return 0xf5deb3, true
	case "white": return 0xffffff, true
	case "whitesmoke": return 0xf5f5f5, true
	case "yellow": return 0xffff00, true
	case "yellowgreen": return 0x9acd32, true
	}
	return 0, false
}
