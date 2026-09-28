package svg

import "core:slice"
import "core:strings"

@(private)
Declaration :: struct {
	name, value: string,
}

// A compound selector made only of an optional type (or `*`), ids and
// classes, e.g. `rect.st0`, `#logo`, `.a.b`. That covers the stylesheets
// design tools emit; rules with combinators, pseudo-classes or attribute
// selectors are skipped rather than guessed at.
@(private)
Selector :: struct {
	tag:         string,
	ids:         [dynamic]string,
	classes:     [dynamic]string,
	specificity: int,
}

@(private)
Css_Rule :: struct {
	selector: Selector,
	decls:    [dynamic]Declaration,
	order:    int,
}

// Parses `name: value; ...` (a `style` attribute or a rule body).
@(private)
parse_declarations :: proc(s: string, out: ^[dynamic]Declaration) {
	rest := s
	for part in strings.split_iterator(&rest, ";") {
		colon := strings.index_byte(part, ':')
		if colon < 0 {continue}
		name := trim(part[:colon])
		value := trim(part[colon + 1:])
		if i := strings.index(value, "!important"); i >= 0 {
			value = trim(value[:i])
		}
		if len(name) > 0 && len(value) > 0 {
			append(out, Declaration{name, value})
		}
	}
}

@(private)
parse_stylesheet :: proc(src: string, rules: ^[dynamic]Css_Rule) {
	s := strip_css_comments(src)
	i := 0
	for i < len(s) {
		for i < len(s) && is_space(s[i]) {i += 1}
		if i >= len(s) {break}

		if s[i] == '@' {
			// At-rules: skip either `@import ...;` or a whole `{ ... }` block.
			depth := 0
			for i < len(s) {
				c := s[i]
				i += 1
				if c == ';' && depth == 0 {break}
				if c == '{' {depth += 1}
				if c == '}' {
					depth -= 1
					if depth <= 0 {break}
				}
			}
			continue
		}

		open := strings.index_byte(s[i:], '{')
		if open < 0 {break}
		selectors := s[i:i + open]
		i += open + 1
		close := strings.index_byte(s[i:], '}')
		if close < 0 {close = len(s) - i}
		body := s[i:i + close]
		i += close + 1

		decls: [dynamic]Declaration
		parse_declarations(body, &decls)
		rest := selectors
		for sel_text in strings.split_iterator(&rest, ",") {
			if sel, ok := parse_selector(trim(sel_text)); ok {
				append(rules, Css_Rule{selector = sel, decls = decls, order = len(rules)})
			}
		}
	}
	// Later rules override earlier ones of equal specificity.
	slice.stable_sort_by(rules[:], proc(a, b: Css_Rule) -> bool {
		return a.selector.specificity < b.selector.specificity
	})
}

@(private = "file")
strip_css_comments :: proc(s: string) -> string {
	if strings.index(s, "/*") < 0 {return s}
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if i + 1 < len(s) && s[i] == '/' && s[i + 1] == '*' {
			end := strings.index(s[i + 2:], "*/")
			if end < 0 {break}
			i += end + 4
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
is_ident_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80
}

@(private = "file")
parse_selector :: proc(s: string) -> (sel: Selector, ok: bool) {
	if len(s) == 0 {return}
	i := 0
	read_ident :: proc(s: string, i: ^int) -> string {
		start := i^
		for i^ < len(s) && is_ident_char(s[i^]) {i^ += 1}
		return s[start:i^]
	}
	if s[0] == '*' {
		i = 1
	} else if is_ident_char(s[0]) {
		sel.tag = read_ident(s, &i)
		sel.specificity += 1
	}
	for i < len(s) {
		c := s[i]
		i += 1
		name := read_ident(s, &i)
		if len(name) == 0 {return}
		switch c {
		case '#':
			append(&sel.ids, name)
			sel.specificity += 10000
		case '.':
			append(&sel.classes, name)
			sel.specificity += 100
		case:
			return
		}
	}
	return sel, true
}

@(private)
selector_matches :: proc(sel: Selector, tag, id, class_attr: string) -> bool {
	if sel.tag != "" && sel.tag != tag {return false}
	for want in sel.ids {
		if want != id {return false}
	}
	for want in sel.classes {
		found := false
		rest := class_attr
		for class in strings.fields_iterator(&rest) {
			if class == want {
				found = true
				break
			}
		}
		if !found {return false}
	}
	return true
}
