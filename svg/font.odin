package svg

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// A minimal OpenType reader: enough to find system fonts by family, map
// characters to glyphs, and turn glyph outlines (TrueType `glyf` quadratics
// or CFF Type 2 charstrings) into paths. No shaping or kerning.

@(private)
Font :: struct {
	data:            []u8, // whole file
	face:            int, // offset of this face's table directory
	units_per_em:    f64,
	num_glyphs:      int,
	num_hmetrics:    int,
	long_loca:       bool,
	cmap:            int, // offset of the chosen cmap subtable, or 0
	hmtx, loca, glyf: int,
	glyf_len:        int,
	// CFF
	cff:             int,
	char_strings:    Cff_Index,
	gsubrs:          Cff_Index,
	subrs:           Cff_Index, // non-CID fonts
	fd_select:       int, // CID fonts: offset of FDSelect, 0 if none
	fd_subrs:        [dynamic]Cff_Index,
}

@(private)
Font_Info :: struct {
	path:   string,
	index:  int, // face index within a collection
	family: string, // lower-case
	weight: int,
	italic: bool,
}

// Process-wide font registry, built on first use: scanning font
// directories is slow and fonts don't change while the viewer runs, so it
// survives document reloads.
@(private = "file")
Font_Db :: struct {
	mutex:   sync.Mutex,
	scanned: bool,
	infos:   [dynamic]Font_Info,
	loaded:  map[string]^Font, // "path#index" -> font (nil if unusable)
}

@(private = "file")
font_db: Font_Db

// ---- binary helpers (out-of-range reads yield 0 rather than crashing on
// a malformed font) ----

@(private = "file")
u8_at :: proc(d: []u8, o: int) -> int {
	return o >= 0 && o < len(d) ? int(d[o]) : 0
}

@(private = "file")
u16_at :: proc(d: []u8, o: int) -> int {
	return o >= 0 && o + 2 <= len(d) ? int(d[o]) << 8 | int(d[o + 1]) : 0
}

@(private = "file")
i16_at :: proc(d: []u8, o: int) -> int {
	return int(i16(u16(u16_at(d, o))))
}

@(private = "file")
u32_at :: proc(d: []u8, o: int) -> int {
	return o >= 0 && o + 4 <= len(d) ? int(d[o]) << 24 | int(d[o + 1]) << 16 | int(d[o + 2]) << 8 | int(d[o + 3]) : 0
}

@(private = "file")
find_table :: proc(d: []u8, face: int, tag: string) -> (offset, length: int) {
	n := u16_at(d, face + 4)
	for i in 0 ..< n {
		rec := face + 12 + 16 * i
		if rec + 16 > len(d) {break}
		if string(d[rec:rec + 4]) == tag {
			offset, length = u32_at(d, rec + 8), u32_at(d, rec + 12)
			if offset + length > len(d) {return 0, 0}
			return
		}
	}
	return 0, 0
}

// Offsets of each face's table directory in an sfnt file or collection.
@(private = "file")
face_offsets :: proc(d: []u8, out: ^[dynamic]int) {
	if len(d) >= 12 && string(d[:4]) == "ttcf" {
		n := u32_at(d, 8)
		for i in 0 ..< min(n, 64) {
			append(out, u32_at(d, 12 + 4 * i))
		}
	} else {
		append(out, 0)
	}
}

// ---- discovery ----

@(private = "file")
font_dirs :: proc() -> [dynamic]string {
	dirs: [dynamic]string
	append(&dirs, "/usr/share/fonts", "/usr/local/share/fonts")
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		append(&dirs, strings.concatenate({home, "/.local/share/fonts"}, context.temp_allocator))
		append(&dirs, strings.concatenate({home, "/.fonts"}, context.temp_allocator))
	}
	when ODIN_OS == .Darwin {
		append(&dirs, "/System/Library/Fonts", "/Library/Fonts")
	}
	when ODIN_OS == .Windows {
		append(&dirs, "C:\\Windows\\Fonts")
	}
	return dirs
}

@(private = "file")
scan_fonts :: proc() {
	dirs := font_dirs()
	defer delete(dirs)
	for dir in dirs {
		scan_dir(dir, 0)
	}
}

@(private = "file")
scan_dir :: proc(dir: string, depth: int) {
	if depth > 8 {return}
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for e in entries {
		if e.type == .Directory {
			scan_dir(e.fullpath, depth + 1)
			continue
		}
		ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
		if ext == ".ttf" || ext == ".otf" || ext == ".ttc" || ext == ".otc" {
			scan_file(e.fullpath)
		}
	}
}

// Reads just the tables needed to index a font (name, OS/2, head), rather
// than whole files: a font directory can hold hundreds of megabytes.
@(private = "file")
scan_file :: proc(path: string) {
	f, err := os.open(path)
	if err != nil {return}
	defer os.close(f)

	read :: proc(f: ^os.File, off, n: int) -> []u8 {
		if n <= 0 || n > 1 << 24 {return nil}
		buf := make([]u8, n, context.temp_allocator)
		got, _ := os.read_at(f, buf, i64(off))
		return buf[:got]
	}
	head := read(f, 0, 12 + 4 * 64)
	faces: [dynamic]int
	faces.allocator = context.temp_allocator
	face_offsets(head, &faces)

	for face, index in faces {
		dir_head := read(f, face, 12)
		n := u16_at(dir_head, 4)
		dir := read(f, face, 12 + 16 * n)
		if len(dir) < 12 + 16 * n {continue}
		sfnt := string(dir[:4])
		if sfnt != "\x00\x01\x00\x00" && sfnt != "OTTO" && sfnt != "true" {continue}

		table :: proc(f: ^os.File, dir: []u8, tag: string) -> []u8 {
			n := u16_at(dir, 4)
			for i in 0 ..< n {
				rec := 12 + 16 * i
				if string(dir[rec:rec + 4]) == tag {
					return read(f, u32_at(dir, rec + 8), u32_at(dir, rec + 12))
				}
			}
			return nil
		}
		name := table(f, dir, "name")
		family := name_string(name, 16)
		if family == "" {family = name_string(name, 1)}
		if family == "" {continue}

		info := Font_Info {
			path   = strings.clone(path),
			index  = index,
			family = strings.to_lower(family),
			weight = 400,
		}
		if os2 := table(f, dir, "OS/2"); len(os2) >= 64 {
			info.weight = u16_at(os2, 4)
			sel := u16_at(os2, 62)
			info.italic = sel & 1 != 0 || sel & (1 << 9) != 0
		} else if h := table(f, dir, "head"); len(h) >= 46 {
			style := u16_at(h, 44)
			if style & 1 != 0 {info.weight = 700}
			info.italic = style & 2 != 0
		}
		append(&font_db.infos, info)
	}
}

// A name-table string (Windows UTF-16BE or Mac Roman), ASCII only.
@(private = "file")
name_string :: proc(name: []u8, want_id: int) -> string {
	count := u16_at(name, 2)
	storage := u16_at(name, 4)
	for pass in 0 ..< 2 {
		for i in 0 ..< count {
			rec := 6 + 12 * i
			platform, id := u16_at(name, rec), u16_at(name, rec + 6)
			lang := u16_at(name, rec + 4)
			length, off := u16_at(name, rec + 8), storage + u16_at(name, rec + 10)
			if id != want_id || off + length > len(name) {continue}
			// Prefer English (Windows 0x409 / Mac 0) on the first pass.
			english := (platform == 3 && lang == 0x409) || (platform == 1 && lang == 0)
			if pass == 0 && !english {continue}
			b := strings.builder_make(context.temp_allocator)
			switch platform {
			case 0, 3:
				for j := 0; j + 1 < length; j += 2 {
					c := u16_at(name, off + j)
					if c < 128 {strings.write_byte(&b, u8(c))}
				}
			case 1:
				for j in 0 ..< length {
					if c := name[off + j]; c < 128 {strings.write_byte(&b, c)}
				}
			case:
				continue
			}
			if s := strings.to_string(b); s != "" {return s}
		}
	}
	return ""
}

// ---- matching ----

@(private = "file")
GENERIC_SANS := []string{"noto sans", "dejavu sans", "verdana", "arial", "liberation sans", "helvetica", "nimbus sans", "freesans", "adwaita sans", "cantarell"}
@(private = "file")
GENERIC_SERIF := []string{"noto serif", "dejavu serif", "times new roman", "liberation serif", "times", "nimbus roman", "freeserif"}
@(private = "file")
GENERIC_MONO := []string{"noto sans mono", "dejavu sans mono", "liberation mono", "courier new", "freemono", "adwaita mono", "jetbrains mono"}

// Finds the font best matching a CSS `font-family` list, weight and style.
// Returns nil if no usable font exists at all.
@(private)
match_font :: proc(families: string, weight: int, italic: bool) -> ^Font {
	sync.mutex_lock(&font_db.mutex)
	defer sync.mutex_unlock(&font_db.mutex)
	{
		context.allocator = runtime.heap_allocator() // outlives any one document
		if !font_db.scanned {
			font_db.scanned = true
			scan_fonts()
		}
	}

	try_family :: proc(family: string, weight: int, italic: bool) -> ^Font {
		best := -1
		best_score := max(int)
		for info, i in font_db.infos {
			if info.family != family {continue}
			score := abs(info.weight - weight) + (info.italic != italic ? 10000 : 0)
			if score < best_score {
				best, best_score = i, score
			}
		}
		return best >= 0 ? load_font(font_db.infos[best]) : nil
	}
	try_list :: proc(list: []string, weight: int, italic: bool) -> ^Font {
		for fam in list {
			if f := try_family(fam, weight, italic); f != nil {return f}
		}
		return nil
	}

	rest := families
	for part in strings.split_iterator(&rest, ",") {
		name := strings.trim(trim(part), "\"'")
		lower := strings.to_lower(name, context.temp_allocator)
		switch lower {
		case "sans-serif", "system-ui", "fantasy", "cursive":
			if f := try_list(GENERIC_SANS, weight, italic); f != nil {return f}
		case "serif":
			if f := try_list(GENERIC_SERIF, weight, italic); f != nil {return f}
		case "monospace":
			if f := try_list(GENERIC_MONO, weight, italic); f != nil {return f}
		case:
			if f := try_family(lower, weight, italic); f != nil {return f}
		}
	}
	// Nothing named is installed: fall back like a browser would.
	if f := try_list(GENERIC_SANS, weight, italic); f != nil {return f}
	for info in font_db.infos {
		if f := try_family(info.family, weight, italic); f != nil {return f}
	}
	return nil
}

@(private = "file")
load_font :: proc(info: Font_Info) -> ^Font {
	context.allocator = runtime.heap_allocator() // outlives any one document
	key := strings.concatenate({info.path, "#", string([]u8{u8('0' + info.index % 10)})})
	if f, seen := font_db.loaded[key]; seen {
		delete(key)
		return f
	}
	f: ^Font
	if data, err := os.read_entire_file(info.path, context.allocator); err == nil {
		faces: [dynamic]int
		defer delete(faces)
		face_offsets(data, &faces)
		if info.index < len(faces) {
			f = new(Font)
			if !font_init(f, data, faces[info.index]) {
				free(f)
				f = nil
			}
		}
		if f == nil {delete(data)}
	}
	font_db.loaded[key] = f
	return f
}

@(private = "file")
font_init :: proc(f: ^Font, data: []u8, face: int) -> bool {
	f.data = data
	f.face = face
	head, _ := find_table(data, face, "head")
	hhea, _ := find_table(data, face, "hhea")
	maxp, _ := find_table(data, face, "maxp")
	if head == 0 || hhea == 0 || maxp == 0 {return false}
	f.units_per_em = f64(u16_at(data, head + 18))
	if f.units_per_em <= 0 {f.units_per_em = 1000}
	f.long_loca = i16_at(data, head + 50) != 0
	f.num_hmetrics = u16_at(data, hhea + 34)
	f.num_glyphs = u16_at(data, maxp + 4)
	f.hmtx, _ = find_table(data, face, "hmtx")
	f.loca, _ = find_table(data, face, "loca")
	f.glyf, f.glyf_len = find_table(data, face, "glyf")

	if cmap, _ := find_table(data, face, "cmap"); cmap != 0 {
		// Prefer full-Unicode (format 12) subtables, then the BMP ones.
		best_rank := 0
		for i in 0 ..< u16_at(data, cmap + 2) {
			rec := cmap + 4 + 8 * i
			platform, encoding := u16_at(data, rec), u16_at(data, rec + 2)
			sub := cmap + u32_at(data, rec + 4)
			format := u16_at(data, sub)
			rank := 0
			switch {
			case format == 12 && (platform == 3 && encoding == 10 || platform == 0):
				rank = 3
			case format == 4 && (platform == 3 && encoding == 1 || platform == 0):
				rank = 2
			case format == 4 && platform == 3 && encoding == 0:
				rank = 1 // symbol fonts
			}
			if rank > best_rank {
				best_rank = rank
				f.cmap = sub
			}
		}
	}

	if f.glyf == 0 {
		cff, _ := find_table(data, face, "CFF ")
		if cff == 0 || !cff_init(f, cff) {return false}
	} else if f.loca == 0 {
		return false
	}
	return true
}

@(private)
font_glyph_index :: proc(f: ^Font, r: rune) -> int {
	d := f.data
	c := int(r)
	if f.cmap == 0 {return 0}
	switch u16_at(d, f.cmap) {
	case 4:
		if c > 0xffff {return 0}
		seg_x2 := u16_at(d, f.cmap + 6)
		ends := f.cmap + 14
		starts := ends + seg_x2 + 2
		deltas := starts + seg_x2
		ranges := deltas + seg_x2
		// Binary search the segment whose end code is >= c.
		lo, hi := 0, seg_x2 / 2
		for lo < hi {
			mid := (lo + hi) / 2
			if u16_at(d, ends + 2 * mid) < c {lo = mid + 1} else {hi = mid}
		}
		if lo >= seg_x2 / 2 {return 0}
		seg := lo
		start := u16_at(d, starts + 2 * seg)
		if c < start {return 0}
		delta := u16_at(d, deltas + 2 * seg)
		range_off := u16_at(d, ranges + 2 * seg)
		if range_off == 0 {return (c + delta) & 0xffff}
		g := u16_at(d, ranges + 2 * seg + range_off + 2 * (c - start))
		return g == 0 ? 0 : (g + delta) & 0xffff
	case 12:
		n := u32_at(d, f.cmap + 12)
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			g := f.cmap + 16 + 12 * mid
			if c < u32_at(d, g) {
				hi = mid
			} else if c > u32_at(d, g + 4) {
				lo = mid + 1
			} else {
				return u32_at(d, g + 8) + c - u32_at(d, g)
			}
		}
	}
	return 0
}

// Horizontal advance in font units.
@(private)
font_advance :: proc(f: ^Font, glyph: int) -> f64 {
	if f.num_hmetrics == 0 {return 0}
	i := min(glyph, f.num_hmetrics - 1)
	return f64(u16_at(f.data, f.hmtx + 4 * i))
}

// Appends `glyph`'s outline to `out`, mapping font units through `m`.
@(private)
font_outline :: proc(f: ^Font, glyph: int, m: Transform, out: ^Path) {
	if glyph < 0 || glyph >= f.num_glyphs {return}
	if f.glyf != 0 {
		glyf_outline(f, glyph, m, out, 0)
	} else {
		cff_outline(f, glyph, m, out)
	}
}

// ---- TrueType outlines ----

@(private = "file")
glyf_outline :: proc(f: ^Font, glyph: int, m: Transform, out: ^Path, depth: int) {
	d := f.data
	start, end: int
	if f.long_loca {
		start, end = u32_at(d, f.loca + 4 * glyph), u32_at(d, f.loca + 4 * glyph + 4)
	} else {
		start, end = 2 * u16_at(d, f.loca + 2 * glyph), 2 * u16_at(d, f.loca + 2 * glyph + 2)
	}
	if end <= start || end > f.glyf_len {return}
	g := f.glyf + start
	contours := i16_at(d, g)

	if contours < 0 {
		// Composite: other glyphs placed with an offset and optional scale.
		if depth > 8 {return}
		ARG_WORDS :: 0x0001
		ARGS_XY :: 0x0002
		HAVE_SCALE :: 0x0008
		MORE :: 0x0020
		XY_SCALE :: 0x0040
		TWO_BY_TWO :: 0x0080
		p := g + 10
		for {
			flags := u16_at(d, p)
			sub := u16_at(d, p + 2)
			p += 4
			dx, dy: f64
			if flags & ARG_WORDS != 0 {
				dx, dy = f64(i16_at(d, p)), f64(i16_at(d, p + 2))
				p += 4
			} else {
				dx, dy = f64(i8(u8(u8_at(d, p)))), f64(i8(u8(u8_at(d, p + 1))))
				p += 2
			}
			if flags & ARGS_XY == 0 {dx, dy = 0, 0} // point matching: unsupported
			a, b, c, e := 1.0, 0.0, 0.0, 1.0
			f2dot14 :: proc(d: []u8, o: int) -> f64 {return f64(i16_at(d, o)) / 16384}
			switch {
			case flags & HAVE_SCALE != 0:
				a = f2dot14(d, p)
				e = a
				p += 2
			case flags & XY_SCALE != 0:
				a, e = f2dot14(d, p), f2dot14(d, p + 2)
				p += 4
			case flags & TWO_BY_TWO != 0:
				a, b, c, e = f2dot14(d, p), f2dot14(d, p + 2), f2dot14(d, p + 4), f2dot14(d, p + 6)
				p += 8
			}
			glyf_outline(f, sub, transform_mul(m, Transform{a, b, c, e, dx, dy}), out, depth + 1)
			if flags & MORE == 0 {break}
		}
		return
	}

	end_pts := g + 10
	n_points := contours > 0 ? u16_at(d, end_pts + 2 * (contours - 1)) + 1 : 0
	if n_points == 0 || n_points > 65535 {return}
	insn_len := u16_at(d, end_pts + 2 * contours)
	p := end_pts + 2 * contours + 2 + insn_len

	flags := make([]u8, n_points, context.temp_allocator)
	for i := 0; i < n_points; {
		fl := u8(u8_at(d, p))
		p += 1
		flags[i] = fl
		i += 1
		if fl & 8 != 0 {
			repeat := u8_at(d, p)
			p += 1
			for _ in 0 ..< repeat {
				if i >= n_points {break}
				flags[i] = fl
				i += 1
			}
		}
	}
	pts := make([]Vec2, n_points, context.temp_allocator)
	v := 0
	for i in 0 ..< n_points {
		fl := flags[i]
		if fl & 2 != 0 {
			dv := u8_at(d, p)
			p += 1
			v += fl & 16 != 0 ? dv : -dv
		} else if fl & 16 == 0 {
			v += i16_at(d, p)
			p += 2
		}
		pts[i].x = f64(v)
	}
	v = 0
	for i in 0 ..< n_points {
		fl := flags[i]
		if fl & 4 != 0 {
			dv := u8_at(d, p)
			p += 1
			v += fl & 32 != 0 ? dv : -dv
		} else if fl & 32 == 0 {
			v += i16_at(d, p)
			p += 2
		}
		pts[i].y = f64(v)
	}

	first := 0
	for ci in 0 ..< contours {
		last := u16_at(d, end_pts + 2 * ci)
		if last >= n_points || last < first {break}
		quad_contour(pts[first:last + 1], flags[first:last + 1], m, out)
		first = last + 1
	}
}

// Emits a TrueType contour: quadratic B-spline where consecutive off-curve
// points imply an on-curve point midway between them.
@(private = "file")
quad_contour :: proc(pts: []Vec2, flags: []u8, m: Transform, out: ^Path) {
	n := len(pts)
	if n < 2 {return}
	on :: proc(flags: []u8, i: int) -> bool {return flags[i] & 1 != 0}

	// Start at an on-curve point, or the midpoint of the first two off ones.
	start_i := -1
	for i in 0 ..< n {
		if on(flags, i) {
			start_i = i
			break
		}
	}
	start: Vec2
	if start_i < 0 {
		start = (pts[0] + pts[1]) / 2
		start_i = 0
	} else {
		start = pts[start_i]
	}
	path_move_to(out, transform_point(m, start))
	cur := start
	ctrl: Maybe(Vec2)
	quad :: proc(out: ^Path, m: Transform, p0, q, p1: Vec2) {
		c1 := p0 + (q - p0) * (2.0 / 3.0)
		c2 := p1 + (q - p1) * (2.0 / 3.0)
		path_cubic_to(out, transform_point(m, c1), transform_point(m, c2), transform_point(m, p1))
	}
	all_off := !on(flags, start_i)
	for k in 1 ..= n {
		i := (start_i + k) % n
		p := pts[i]
		if all_off && k == n {
			// Wrap back to the synthesized start point.
			if c, has := ctrl.?; has {quad(out, m, cur, c, start)}
			ctrl = nil
			break
		}
		if on(flags, i) {
			if c, has := ctrl.?; has {
				quad(out, m, cur, c, p)
				ctrl = nil
			} else {
				path_line_to(out, transform_point(m, p))
			}
			cur = p
		} else {
			if c, has := ctrl.?; has {
				mid := (c + p) / 2
				quad(out, m, cur, c, mid)
				cur = mid
			}
			ctrl = p
		}
	}
	if c, has := ctrl.?; has {quad(out, m, cur, c, start)}
	path_close(out)
}

// ---- CFF outlines ----

@(private)
Cff_Index :: struct {
	count:    int,
	off_size: int,
	offsets:  int, // position of the offset array
	data:     int, // position just before the first byte of object data
	end:      int, // position after the index
}

@(private = "file")
cff_index :: proc(d: []u8, at: int) -> Cff_Index {
	idx := Cff_Index{count = u16_at(d, at)}
	if idx.count == 0 {
		idx.end = at + 2
		return idx
	}
	idx.off_size = u8_at(d, at + 2)
	idx.offsets = at + 3
	idx.data = idx.offsets + (idx.count + 1) * idx.off_size - 1
	idx.end = idx.data + cff_offset(d, idx, idx.count)
	return idx
}

@(private = "file")
cff_offset :: proc(d: []u8, idx: Cff_Index, i: int) -> int {
	o := idx.offsets + i * idx.off_size
	v := 0
	for k in 0 ..< idx.off_size {
		v = v << 8 | u8_at(d, o + k)
	}
	return v
}

// Byte range of object `i`.
@(private = "file")
cff_object :: proc(d: []u8, idx: Cff_Index, i: int) -> (start, end: int, ok: bool) {
	if i < 0 || i >= idx.count {return}
	start = idx.data + cff_offset(d, idx, i)
	end = idx.data + cff_offset(d, idx, i + 1)
	return start, end, start <= end && end <= len(d)
}

// Reads a DICT, returning the operands of `op` (two-byte ops as 1200+b).
@(private = "file")
cff_dict_get :: proc(d: []u8, start, end: int, op: int) -> (vals: [4]f64, n: int, found: bool) {
	stack: [48]f64
	sp := 0
	for p := start; p < end; {
		b := u8_at(d, p)
		switch {
		case b <= 21:
			key := b
			p += 1
			if b == 12 {
				key = 1200 + u8_at(d, p)
				p += 1
			}
			if key == op {
				for i in 0 ..< min(sp, 4) {vals[i] = stack[i]}
				return vals, min(sp, 4), true
			}
			sp = 0
			continue
		case b == 28:
			if sp < len(stack) {stack[sp] = f64(i16_at(d, p + 1)); sp += 1}
			p += 3
		case b == 29:
			if sp < len(stack) {stack[sp] = f64(i32(u32(u32_at(d, p + 1)))); sp += 1}
			p += 5
		case b == 30:
			// Real number: nibbles until 0xf. Only its extent matters here.
			p += 1
			for p < end {
				v := u8_at(d, p)
				p += 1
				if v & 0xf == 0xf || v >> 4 == 0xf {break}
			}
			if sp < len(stack) {stack[sp] = 0; sp += 1}
		case b >= 32 && b <= 246:
			if sp < len(stack) {stack[sp] = f64(b - 139); sp += 1}
			p += 1
		case b >= 247 && b <= 250:
			if sp < len(stack) {stack[sp] = f64((b - 247) * 256 + u8_at(d, p + 1) + 108); sp += 1}
			p += 2
		case b >= 251 && b <= 254:
			if sp < len(stack) {stack[sp] = f64(-(b - 251) * 256 - u8_at(d, p + 1) - 108); sp += 1}
			p += 2
		case:
			p += 1
		}
	}
	return
}

@(private = "file")
cff_private_subrs :: proc(d: []u8, cff: int, dict_start, dict_end: int) -> Cff_Index {
	priv, n, has := cff_dict_get(d, dict_start, dict_end, 18)
	if !has || n < 2 {return {}}
	size, off := int(priv[0]), int(priv[1])
	subrs, _, has_subrs := cff_dict_get(d, cff + off, cff + off + size, 19)
	if !has_subrs {return {}}
	return cff_index(d, cff + off + int(subrs[0]))
}

@(private = "file")
cff_init :: proc(f: ^Font, cff: int) -> bool {
	d := f.data
	f.cff = cff
	names := cff_index(d, cff + u8_at(d, cff + 2))
	top := cff_index(d, names.end)
	strs := cff_index(d, top.end)
	f.gsubrs = cff_index(d, strs.end)
	ts, te, ok := cff_object(d, top, 0)
	if !ok {return false}

	cs, _, has_cs := cff_dict_get(d, ts, te, 17)
	if !has_cs {return false}
	f.char_strings = cff_index(d, cff + int(cs[0]))

	if fda, _, is_cid := cff_dict_get(d, ts, te, 1236); is_cid {
		fds, _, _ := cff_dict_get(d, ts, te, 1237)
		f.fd_select = cff + int(fds[0])
		fd_array := cff_index(d, cff + int(fda[0]))
		for i in 0 ..< fd_array.count {
			s, e, fok := cff_object(d, fd_array, i)
			append(&f.fd_subrs, fok ? cff_private_subrs(d, cff, s, e) : Cff_Index{})
		}
	} else {
		f.subrs = cff_private_subrs(d, cff, ts, te)
	}
	return f.char_strings.count > 0
}

@(private = "file")
cff_fd_for_glyph :: proc(f: ^Font, glyph: int) -> int {
	d := f.data
	p := f.fd_select
	switch u8_at(d, p) {
	case 0:
		return u8_at(d, p + 1 + glyph)
	case 3:
		n := u16_at(d, p + 1)
		for i in 0 ..< n {
			r := p + 3 + 3 * i
			if glyph >= u16_at(d, r) && glyph < u16_at(d, r + 3) {return u8_at(d, r + 2)}
		}
	}
	return 0
}

@(private = "file")
subr_bias :: proc(count: int) -> int {
	if count < 1240 {return 107}
	if count < 33900 {return 1131}
	return 32768
}

@(private = "file")
Cff_State :: struct {
	f:           ^Font,
	m:           Transform,
	out:         ^Path,
	subrs:       Cff_Index,
	stack:       [48]f64,
	sp:          int,
	pos:         Vec2,
	open:        bool, // a subpath has been started
	stems:       int,
	have_width:  bool,
	done:        bool,
}

@(private = "file")
cff_outline :: proc(f: ^Font, glyph: int, m: Transform, out: ^Path) {
	s, e, ok := cff_object(f.data, f.char_strings, glyph)
	if !ok {return}
	st := Cff_State{f = f, m = m, out = out, subrs = f.subrs}
	if f.fd_select != 0 {
		fd := cff_fd_for_glyph(f, glyph)
		if fd < len(f.fd_subrs) {st.subrs = f.fd_subrs[fd]}
	}
	cff_run(&st, s, e, 0)
	if st.open {path_close(out)}
}

@(private = "file")
cff_run :: proc(st: ^Cff_State, start, end: int, depth: int) {
	if depth > 10 {
		st.done = true
		return
	}
	d := st.f.data
	push :: proc(st: ^Cff_State, v: f64) {
		if st.sp < len(st.stack) {
			st.stack[st.sp] = v
			st.sp += 1
		}
	}
	move :: proc(st: ^Cff_State, dx, dy: f64) {
		if st.open {path_close(st.out)}
		st.pos += {dx, dy}
		path_move_to(st.out, transform_point(st.m, st.pos))
		st.open = true
	}
	line :: proc(st: ^Cff_State, dx, dy: f64) {
		st.pos += {dx, dy}
		path_line_to(st.out, transform_point(st.m, st.pos))
	}
	curve :: proc(st: ^Cff_State, dx1, dy1, dx2, dy2, dx3, dy3: f64) {
		c1 := st.pos + {dx1, dy1}
		c2 := c1 + {dx2, dy2}
		st.pos = c2 + {dx3, dy3}
		path_cubic_to(st.out, transform_point(st.m, c1), transform_point(st.m, c2), transform_point(st.m, st.pos))
	}
	// The first stack-clearing operator may carry the glyph's advance width
	// as an extra leading operand; returns how many operands to skip.
	strip_width :: proc(st: ^Cff_State, has_width: bool) -> int {
		if st.have_width {return 0}
		st.have_width = true
		return has_width ? 1 : 0
	}

	for p := start; p < end && !st.done; {
		b := u8_at(d, p)
		p += 1
		switch {
		case b == 28:
			push(st, f64(i16_at(d, p)))
			p += 2
			continue
		case b >= 32 && b <= 246:
			push(st, f64(b - 139))
			continue
		case b >= 247 && b <= 250:
			push(st, f64((b - 247) * 256 + u8_at(d, p) + 108))
			p += 1
			continue
		case b >= 251 && b <= 254:
			push(st, f64(-(b - 251) * 256 - u8_at(d, p) - 108))
			p += 1
			continue
		case b == 255:
			push(st, f64(i32(u32(u32_at(d, p)))) / 65536)
			p += 4
			continue
		}

		a := st.stack[:st.sp]
		switch b {
		case 1, 3, 18, 23: // hstem, vstem, hstemhm, vstemhm
			base := strip_width(st, st.sp % 2 == 1)
			st.stems += (st.sp - base) / 2
		case 19, 20: // hintmask, cntrmask: implicit vstem, then mask bytes
			base := strip_width(st, st.sp % 2 == 1)
			st.stems += (st.sp - base) / 2
			p += (st.stems + 7) / 8
		case 21: // rmoveto
			base := strip_width(st, st.sp > 2)
			if st.sp - base >= 2 {move(st, a[base], a[base + 1])}
		case 22: // hmoveto
			base := strip_width(st, st.sp > 1)
			if st.sp - base >= 1 {move(st, a[base], 0)}
		case 4: // vmoveto
			base := strip_width(st, st.sp > 1)
			if st.sp - base >= 1 {move(st, 0, a[base])}
		case 5: // rlineto
			for i := 0; i + 1 < st.sp; i += 2 {line(st, a[i], a[i + 1])}
		case 6, 7: // hlineto, vlineto: alternating
			horizontal := b == 6
			for i in 0 ..< st.sp {
				if horizontal {line(st, a[i], 0)} else {line(st, 0, a[i])}
				horizontal = !horizontal
			}
		case 8: // rrcurveto
			for i := 0; i + 5 < st.sp; i += 6 {
				curve(st, a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5])
			}
		case 24: // rcurveline
			i := 0
			for ; i + 5 < st.sp - 2; i += 6 {
				curve(st, a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5])
			}
			if i + 1 < st.sp {line(st, a[i], a[i + 1])}
		case 25: // rlinecurve
			i := 0
			for ; i + 1 < st.sp - 6; i += 2 {line(st, a[i], a[i + 1])}
			if i + 5 < st.sp {curve(st, a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5])}
		case 26: // vvcurveto
			i := 0
			dx1 := 0.0
			if st.sp % 2 == 1 {dx1 = a[0]; i = 1}
			for ; i + 3 < st.sp; i += 4 {
				curve(st, dx1, a[i], a[i + 1], a[i + 2], 0, a[i + 3])
				dx1 = 0
			}
		case 27: // hhcurveto
			i := 0
			dy1 := 0.0
			if st.sp % 2 == 1 {dy1 = a[0]; i = 1}
			for ; i + 3 < st.sp; i += 4 {
				curve(st, a[i], dy1, a[i + 1], a[i + 2], a[i + 3], 0)
				dy1 = 0
			}
		case 30, 31: // vhcurveto, hvcurveto: alternating start tangents
			horizontal := b == 31
			for i := 0; i + 3 < st.sp; i += 4 {
				last := i + 5 == st.sp ? a[i + 4] : 0
				if horizontal {
					curve(st, a[i], 0, a[i + 1], a[i + 2], last, a[i + 3])
				} else {
					curve(st, 0, a[i], a[i + 1], a[i + 2], a[i + 3], last)
				}
				horizontal = !horizontal
			}
		case 10, 29: // callsubr, callgsubr
			if st.sp == 0 {return}
			st.sp -= 1
			idx := b == 10 ? st.subrs : st.f.gsubrs
			n := int(st.stack[st.sp]) + subr_bias(idx.count)
			if s, e, ok := cff_object(d, idx, n); ok {
				cff_run(st, s, e, depth + 1)
			}
			continue // the subroutine's operands/results stay on the stack
		case 11: // return
			return
		case 14: // endchar
			st.done = true
			return
		case 12:
			op := u8_at(d, p)
			p += 1
			switch op {
			case 35: // flex
				if st.sp >= 12 {
					curve(st, a[0], a[1], a[2], a[3], a[4], a[5])
					curve(st, a[6], a[7], a[8], a[9], a[10], a[11])
				}
			case 34: // hflex
				if st.sp >= 7 {
					curve(st, a[0], 0, a[1], a[2], a[3], 0)
					curve(st, a[4], 0, a[5], -a[2], a[6], 0)
				}
			case 36: // hflex1
				if st.sp >= 9 {
					y := st.pos.y
					curve(st, a[0], a[1], a[2], a[3], a[4], 0)
					curve(st, a[5], 0, a[6], a[7], a[8], y - st.pos.y - a[7])
				}
			case 37: // flex1
				if st.sp >= 11 {
					startp := st.pos
					dx := a[0] + a[2] + a[4] + a[6] + a[8]
					dy := a[1] + a[3] + a[5] + a[7] + a[9]
					curve(st, a[0], a[1], a[2], a[3], a[4], a[5])
					if abs(dx) > abs(dy) {
						curve(st, a[6], a[7], a[8], a[9], a[10], startp.y - (st.pos.y + a[7] + a[9]))
					} else {
						curve(st, a[6], a[7], a[8], a[9], startp.x - (st.pos.x + a[6] + a[8]), a[10])
					}
				}
			}
		}
		st.sp = 0
	}
}
