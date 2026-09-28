package main

import "core:fmt"
import "core:os"
import "core:strings"
import svg "svg"
import rl "vendor:raylib"

main :: proc() {
	args, err, help := parse_args(os.args[1:])
	if help {
		fmt.print(USAGE)
		return
	}
	if err != "" {
		fmt.eprintfln("error: %s\n\nUsage: svgview <FILE> [OPTIONS]\n\nFor more information, try '--help'.", err)
		os.exit(2)
	}

	if !os.exists(args.file) {
		fmt.eprintfln("error: file not found: %s", args.file)
		os.exit(1)
	}

	doc, load_err := svg.load(args.file)
	if load_err != "" {
		fmt.eprintfln("error: %s", load_err)
		os.exit(1)
	}
	for w in doc.warnings {
		fmt.eprintfln("warning: %s", w)
	}

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI, .VSYNC_HINT})
	title := strings.clone_to_cstring(fmt.tprintf("SVG Viewer — %s", args.file))
	rl.InitWindow(i32(args.width), i32(args.height), title)
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(60)

	app: App
	app_init(&app, args.file, doc, args.background)
	defer app_destroy(&app)

	for !rl.WindowShouldClose() && !app.quit {
		app_frame(&app)
		free_all(context.temp_allocator)
	}
}
