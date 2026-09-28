package svg

import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:mem/virtual"
import "core:os"

Fill_Rule :: enum u8 {
	Non_Zero,
	Even_Odd,
}

Line_Cap :: enum u8 {
	Butt,
	Round,
	Square,
}

Line_Join :: enum u8 {
	Miter,
	Round,
	Bevel,
}

Spread :: enum u8 {
	Pad,
	Reflect,
	Repeat,
}

Stop :: struct {
	offset: f32,
	color:  Color,
}

Gradient :: struct {
	radial:            bool,
	// Coordinates are fractions of the painted shape's bounding box rather
	// than user-space lengths (`gradientUnits="objectBoundingBox"`).
	object_bbox_units: bool,
	transform:         Transform,
	spread:            Spread,
	start, end:        Vec2, // linear
	center, focal:     Vec2, // radial
	radius:            f64,
	stops:             []Stop,
}

Paint :: struct {
	kind:     enum u8 {
		Solid,
		Gradient,
	},
	color:    Color,
	gradient: ^Gradient,
}

Fill :: struct {
	paint:   Paint,
	opacity: f32,
	rule:    Fill_Rule,
}

Stroke :: struct {
	paint:       Paint,
	opacity:     f32,
	width:       f64,
	miter_limit: f64,
	cap:         Line_Cap,
	join:        Line_Join,
	dashes:      []f64, // even-length, positive sum; empty for a solid line
	dash_offset: f64,
}

Shape :: struct {
	transform: Transform,
	path:      Path,
	fill:      Maybe(Fill),
	stroke:    Maybe(Stroke),
	// Both in the shape's own user space (before `transform`). `bbox` is the
	// geometry's object bounding box; `bounds` also covers the stroke.
	bbox:      Rect,
	bounds:    Rect,
}

// A clip region: the union of `items`, optionally intersected with `clip`.
Clip_Path :: struct {
	object_bbox_units: bool,
	transform:         Transform,
	items:             [dynamic]Clip_Item,
	clip:              ^Clip_Path,
}

Clip_Item :: struct {
	transform: Transform,
	path:      Path,
	rule:      Fill_Rule,
}

Group :: struct {
	transform: Transform,
	opacity:   f32,
	clip:      ^Clip_Path,
	children:  [dynamic]Node,
	// Union of the children's `bbox`/`bounds`, in the group's own space
	// (children's transforms applied, the group's not).
	bbox:      Rect,
	bounds:    Rect,
}

Node :: union {
	^Group,
	^Shape,
}

// A parsed, fully resolved SVG: styles are cascaded, `<use>` references
// expanded and gradients/clip paths looked up, so rendering is a plain walk
// over the tree. Everything is allocated from `arena`.
Document :: struct {
	width, height: f64,
	root:          ^Group,
	coord_extent:  f64,
	// Human-readable notes about features the document uses that this
	// renderer skips (text, filters, ...).
	warnings:      [dynamic]string,
	arena:         virtual.Arena,
}

// Loads and parses the SVG (or gzipped SVGZ) at `path`. On failure `err`
// is a message allocated with `context.allocator`.
load :: proc(path: string) -> (doc: ^Document, err: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return nil, fmt.aprintf("failed to read SVG file: %s: %s", path, os.error_string(read_err))
	}
	defer delete(data)

	parse_err: string
	doc, parse_err = load_data(data)
	if parse_err != "" {
		err = fmt.aprintf("invalid SVG: %s: %s", path, parse_err)
		delete(parse_err)
	}
	return
}

// Parses SVG/SVGZ bytes. On failure `err` is a message allocated with
// `context.allocator`.
load_data :: proc(data: []u8) -> (doc: ^Document, err: string) {
	caller_allocator := context.allocator
	doc = new(Document)
	if virtual.arena_init_growing(&doc.arena) != nil {
		free(doc)
		return nil, fmt.aprintf("out of memory")
	}
	ok: bool
	{
		context.allocator = virtual.arena_allocator(&doc.arena)
		data := data
		if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
			buf: bytes.Buffer
			if gzip.load_from_bytes(data, &buf) != nil {
				err = fmt.aprintf("failed to decompress SVGZ data", allocator = caller_allocator)
			} else {
				data = bytes.buffer_to_bytes(&buf)
			}
		}
		if err == "" {
			message: string
			ok, message = parse_document(doc, data)
			if !ok {
				err = fmt.aprintf("%s", message, allocator = caller_allocator)
			}
		}
	}
	if err != "" {
		destroy(doc)
		return nil, err
	}
	return doc, ""
}

destroy :: proc(doc: ^Document) {
	if doc == nil {return}
	virtual.arena_destroy(&doc.arena)
	free(doc)
}

node_bbox :: proc(n: Node) -> Rect {
	switch v in n {
	case ^Group:
		return rect_transform(v.transform, v.bbox)
	case ^Shape:
		return rect_transform(v.transform, v.bbox)
	}
	return EMPTY_RECT
}

node_bounds :: proc(n: Node) -> Rect {
	switch v in n {
	case ^Group:
		return rect_transform(v.transform, v.bounds)
	case ^Shape:
		return rect_transform(v.transform, v.bounds)
	}
	return EMPTY_RECT
}
