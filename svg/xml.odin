package svg

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// A small non-validating XML parser. Unlike `core:encoding/xml` it keeps
// text exactly as written (SVG text layout depends on inter-element
// whitespace) and expands entities declared in the DOCTYPE's internal
// subset, which design tools such as Illustrator use in exports.

@(private)
Element_ID :: u32

@(private)
Attribute :: struct {
	key, val: string,
}

@(private)
Value :: union {
	string,
	Element_ID,
}

@(private)
Element :: struct {
	ident:   string,
	attribs: [dynamic]Attribute,
	value:   [dynamic]Value, // text and child elements, in document order
	parent:  Element_ID,
}

@(private)
Xml_Document :: struct {
	elements: [dynamic]Element, // [0] is the root
}

@(private = "file")
Xml_Parser :: struct {
	s:        string,
	i:        int,
	entities: map[string]string,
	err:      string,
}

@(private)
parse_xml :: proc(src: string) -> (doc: ^Xml_Document, err: Maybe(string)) {
	p := Xml_Parser{s = src}
	if strings.has_prefix(p.s, "\xef\xbb\xbf") {p.i = 3}
	doc = new(Xml_Document)

	// Prolog: declarations, comments, DOCTYPE, processing instructions.
	for {
		skip_ws(&p)
		switch {
		case at(&p, "<?"):
			skip_past(&p, "?>") or_return
		case at(&p, "<!--"):
			skip_past(&p, "-->") or_return
		case at(&p, "<!DOCTYPE"):
			parse_doctype(&p) or_return
		case at(&p, "<"):
			parse_elements(&p, doc) or_return
			return doc, nil
		case:
			return nil, fail(&p, "expected the root element")
		}
	}
}

@(private = "file")
fail :: proc(p: ^Xml_Parser, msg: string) -> Maybe(string) {
	line, col := 1, 1
	for c in p.s[:min(p.i, len(p.s))] {
		if c == '\n' {
			line += 1
			col = 1
		} else {
			col += 1
		}
	}
	return fmt.tprintf("%s at line %d, column %d", msg, line, col)
}

@(private = "file")
at :: proc(p: ^Xml_Parser, prefix: string) -> bool {
	return strings.has_prefix(p.s[p.i:], prefix)
}

@(private = "file")
skip_ws :: proc(p: ^Xml_Parser) {
	for p.i < len(p.s) && is_space(p.s[p.i]) {p.i += 1}
}

@(private = "file")
skip_past :: proc(p: ^Xml_Parser, end: string) -> (err: Maybe(string)) {
	j := strings.index(p.s[p.i:], end)
	if j < 0 {
		p.i = len(p.s)
		return fail(p, fmt.tprintf("missing '%s'", end))
	}
	p.i += j + len(end)
	return nil
}

@(private = "file")
is_name_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == ':' || c == '-' || c == '.' || c >= 0x80
}

@(private = "file")
read_name :: proc(p: ^Xml_Parser) -> string {
	start := p.i
	for p.i < len(p.s) && is_name_char(p.s[p.i]) {p.i += 1}
	return p.s[start:p.i]
}

// `<!DOCTYPE name ... [ internal subset ]>`: records `<!ENTITY n "v">`
// declarations and skips everything else.
@(private = "file")
parse_doctype :: proc(p: ^Xml_Parser) -> (err: Maybe(string)) {
	p.i += len("<!DOCTYPE")
	for p.i < len(p.s) {
		c := p.s[p.i]
		switch c {
		case '>':
			p.i += 1
			return nil
		case '"', '\'':
			p.i += 1
			j := strings.index_byte(p.s[p.i:], c)
			if j < 0 {return fail(p, "unterminated DOCTYPE")}
			p.i += j + 1
		case '[':
			p.i += 1
			for {
				skip_ws(p)
				if p.i >= len(p.s) {return fail(p, "unterminated DOCTYPE")}
				switch {
				case at(p, "]"):
					p.i += 1
					break
				case at(p, "<!--"):
					skip_past(p, "-->") or_return
					continue
				case at(p, "<!ENTITY"):
					p.i += len("<!ENTITY")
					skip_ws(p)
					name := read_name(p)
					skip_ws(p)
					if p.i < len(p.s) && (p.s[p.i] == '"' || p.s[p.i] == '\'') {
						q := p.s[p.i]
						p.i += 1
						j := strings.index_byte(p.s[p.i:], q)
						if j < 0 {return fail(p, "unterminated entity")}
						if name not_in p.entities {
							p.entities[name] = p.s[p.i:p.i + j]
						}
						p.i += j + 1
					}
					skip_past(p, ">") or_return
					continue
				case:
					skip_past(p, ">") or_return
					continue
				}
				break
			}
		case:
			p.i += 1
		}
	}
	return fail(p, "unterminated DOCTYPE")
}

@(private = "file")
parse_elements :: proc(p: ^Xml_Parser, doc: ^Xml_Document) -> (err: Maybe(string)) {
	stack: [dynamic]Element_ID
	defer delete(stack)

	open_element :: proc(p: ^Xml_Parser, doc: ^Xml_Document, stack: ^[dynamic]Element_ID) -> (err: Maybe(string)) {
		p.i += 1 // '<'
		name := read_name(p)
		if name == "" {return fail(p, "expected an element name")}
		id := Element_ID(len(doc.elements))
		append(&doc.elements, Element{ident = name})
		if len(stack) > 0 {
			parent := stack[len(stack) - 1]
			doc.elements[id].parent = parent
			append(&doc.elements[parent].value, id)
		}
		for {
			skip_ws(p)
			if p.i >= len(p.s) {return fail(p, "unterminated tag")}
			switch {
			case at(p, "/>"):
				p.i += 2
				return nil
			case at(p, ">"):
				p.i += 1
				append(stack, id)
				return nil
			}
			key := read_name(p)
			if key == "" {return fail(p, "expected an attribute name")}
			skip_ws(p)
			if !at(p, "=") {return fail(p, "expected '=' after attribute name")}
			p.i += 1
			skip_ws(p)
			if p.i >= len(p.s) || (p.s[p.i] != '"' && p.s[p.i] != '\'') {
				return fail(p, "expected a quoted attribute value")
			}
			q := p.s[p.i]
			p.i += 1
			j := strings.index_byte(p.s[p.i:], q)
			if j < 0 {return fail(p, "unterminated attribute value")}
			raw := p.s[p.i:p.i + j]
			p.i += j + 1
			append(&doc.elements[id].attribs, Attribute{key, decode(p, raw, true)})
		}
	}

	open_element(p, doc, &stack) or_return
	for len(stack) > 0 {
		if p.i >= len(p.s) {
			return fail(p, fmt.tprintf("missing </%s>", doc.elements[stack[len(stack) - 1]].ident))
		}
		cur := stack[len(stack) - 1]
		switch {
		case at(p, "<!--"):
			skip_past(p, "-->") or_return
		case at(p, "<![CDATA["):
			p.i += len("<![CDATA[")
			j := strings.index(p.s[p.i:], "]]>")
			if j < 0 {return fail(p, "unterminated CDATA section")}
			append(&doc.elements[cur].value, p.s[p.i:p.i + j])
			p.i += j + 3
		case at(p, "<?"):
			skip_past(p, "?>") or_return
		case at(p, "</"):
			p.i += 2
			name := read_name(p)
			if name != doc.elements[cur].ident {
				return fail(p, fmt.tprintf("expected </%s>, found </%s>", doc.elements[cur].ident, name))
			}
			skip_ws(p)
			if !at(p, ">") {return fail(p, "expected '>'")}
			p.i += 1
			pop(&stack)
		case at(p, "<"):
			open_element(p, doc, &stack) or_return
		case:
			j := strings.index_byte(p.s[p.i:], '<')
			if j < 0 {j = len(p.s) - p.i}
			append(&doc.elements[cur].value, decode(p, p.s[p.i:p.i + j], false))
			p.i += j
		}
	}
	return nil
}

// Expands character and entity references. Attribute values also get
// XML's whitespace normalization (tabs/newlines become spaces).
@(private = "file")
decode :: proc(p: ^Xml_Parser, raw: string, attribute: bool, depth := 0) -> string {
	if strings.index_byte(raw, '&') < 0 && (!attribute || strings.index_any(raw, "\t\n\r") < 0) {
		return raw
	}
	b := strings.builder_make()
	for i := 0; i < len(raw); {
		c := raw[i]
		if attribute && (c == '\t' || c == '\n' || c == '\r') {
			strings.write_byte(&b, ' ')
			i += 1
			continue
		}
		if c != '&' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		semi := strings.index_byte(raw[i:], ';')
		if semi < 0 {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		name := raw[i + 1:i + semi]
		i += semi + 1
		switch name {
		case "lt":
			strings.write_byte(&b, '<')
		case "gt":
			strings.write_byte(&b, '>')
		case "amp":
			strings.write_byte(&b, '&')
		case "quot":
			strings.write_byte(&b, '"')
		case "apos":
			strings.write_byte(&b, '\'')
		case:
			if strings.has_prefix(name, "#") {
				code: int
				ok: bool
				if strings.has_prefix(name, "#x") || strings.has_prefix(name, "#X") {
					code, ok = strconv.parse_int(name[2:], 16)
				} else {
					code, ok = strconv.parse_int(name[1:], 10)
				}
				if ok && code > 0 && code <= 0x10ffff {
					buf, n := utf8.encode_rune(rune(code))
					strings.write_bytes(&b, buf[:n])
				}
			} else if v, has := p.entities[name]; has && depth < 8 {
				strings.write_string(&b, decode(p, v, attribute, depth + 1))
			}
		}
	}
	return strings.to_string(b)
}
