package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import svg "svg"

Args :: struct {
	file:       string,
	background: Maybe(svg.Color),
	width:      int,
	height:     int,
}

USAGE :: `A simple SVG viewer

Usage: svgview <FILE> [OPTIONS]

Arguments:
  <FILE>  Path to the SVG file to view

Options:
  -b, --background <BACKGROUND>  Background color behind transparent areas (e.g. "white", "#222", "#ff000080")
      --width <WIDTH>            Initial window width in pixels [default: 1024]
      --height <HEIGHT>          Initial window height in pixels [default: 768]
  -h, --help                     Print help
`

// Parses command-line arguments (without the program name). On failure,
// returns a message to print before exiting; `help` asks for the usage text.
parse_args :: proc(argv: []string) -> (args: Args, err: string, help: bool) {
	args.width = 1024
	args.height = 768

	i := 0
	for i < len(argv) {
		arg := argv[i]
		i += 1

		name, value := arg, ""
		has_value := false
		if strings.has_prefix(arg, "--") {
			if eq := strings.index_byte(arg, '='); eq >= 0 {
				name, value, has_value = arg[:eq], arg[eq + 1:], true
			}
		}
		take_value :: proc(argv: []string, i: ^int, name: string, value: ^string, has_value: ^bool) -> (err: string) {
			if has_value^ {return ""}
			if i^ >= len(argv) {
				return fmt.tprintf("a value is required for '%s'", name)
			}
			value^ = argv[i^]
			i^ += 1
			has_value^ = true
			return ""
		}

		switch name {
		case "-h", "--help":
			return args, "", true
		case "-b", "--background":
			if e := take_value(argv, &i, name, &value, &has_value); e != "" {return args, e, false}
			color, ok := svg.parse_color(value)
			if !ok {return args, fmt.tprintf("invalid --background color %q", value), false}
			args.background = color
		case "--width", "--height":
			if e := take_value(argv, &i, name, &value, &has_value); e != "" {return args, e, false}
			n, ok := strconv.parse_int(value, 10)
			if !ok || n <= 0 {return args, fmt.tprintf("invalid value %q for '%s'", value, name), false}
			if name == "--width" {args.width = n} else {args.height = n}
		case:
			if strings.has_prefix(arg, "-") && arg != "-" {
				return args, fmt.tprintf("unexpected argument '%s'", arg), false
			}
			if args.file != "" {
				return args, fmt.tprintf("unexpected argument '%s'", arg), false
			}
			args.file = arg
		}
	}
	if args.file == "" {
		return args, "the following required argument was not provided: <FILE>", false
	}
	return args, "", false
}
