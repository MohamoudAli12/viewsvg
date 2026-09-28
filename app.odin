package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import svg "svg"
import rl "vendor:raylib"

MIN_SCALE :: 0.01

// Precision budget for deep zoom: the largest `scale * coordinate` product
// the renderer is allowed to see, in device pixels.
//
// The renderer maps SVG geometry to device space in f64 before rasterizing,
// so this product is what's left to place an edge within f64's 53-bit
// mantissa (~9e15). At 1e11 an edge is still positioned to ~1e-5 px, and
// curve flattening (whose tolerance is 0.1 px mapped back to user units)
// keeps several orders of magnitude of headroom above a coordinate's ulp.
//
// A fixed maximum scale can't express this, because the product depends on
// the document: the same scale is exact for a 24-unit icon and broken for a
// 10000-unit map. Deriving the ceiling per document instead (see
// `max_scale_for_extent`) leaves every document with roughly
// `MAX_COORD_MAGNITUDE / viewport_px` of magnification beyond fit-to-window.
MAX_COORD_MAGNITUDE :: 1e11

// Screen points per second of keyboard-driven panning.
KEY_PAN_SPEED :: 600.0

// Multiplicative zoom step applied per `+`/`-` key press.
KEY_ZOOM_STEP :: 1.25

// Zoom factor per mouse-wheel notch: e^(50 points * 0.0025).
SCROLL_ZOOM_PER_NOTCH :: 0.125

// How long a reload-error banner stays visible.
ERROR_BANNER_DURATION :: 6 * time.Second

// How long to wait after the last pan/zoom before doing a full re-rasterize.
// While this window is open, the last-rendered texture is just drawn
// stretched to the live view instead: cheap, and keeps zooming smooth even on
// complex SVGs.
ZOOM_SETTLE_DELAY :: 120 * time.Millisecond

// Hard cap on the resolution of a *whole-document* raster, independent of how
// far the user has zoomed. Without this, zooming in on a document with a
// large native size could balloon the texture up to the GPU's limit
// (hundreds of MB), making every re-render and upload slow. It deliberately
// does not apply to the cropped path below, whose resolution is already
// bounded by the window.
MAX_RASTER_DIMENSION :: 4096

// raylib doesn't expose GL_MAX_TEXTURE_SIZE; every GPU that runs its
// OpenGL 3.3 backend supports at least this.
MAX_TEXTURE_SIDE :: 8192

WINDOW_BACKGROUND :: rl.Color{27, 27, 27, 255}

Raster_Key :: struct {
	px_width, px_height: int,
	generation:          u64,
	// SVG-space region being rasterized when zoomed in past the resolution
	// cap; unset means the whole document (the common case, and cheap to
	// keep rendered since it doesn't change as the user pans).
	has_crop:            bool,
	crop:                svg.Rect,
}

App :: struct {
	path:             string,
	doc:              ^svg.Document,
	background:       Maybe(svg.Color),
	view:             View_State,
	generation:       u64,
	texture:          Maybe(rl.Texture2D),
	// SVG-space rect (in document user units) that `texture` depicts.
	texture_rect:     svg.Rect,
	last_key:         Maybe(Raster_Key),
	watcher:          Watcher,
	last_interaction: time.Time,
	dragging:         bool,
	quit:             bool,
	// Message and time of the most recent failed reload, shown as an
	// in-window banner since stderr isn't visible when launched from an editor.
	reload_error:     string,
	reload_error_at:  time.Time,
}

app_init :: proc(app: ^App, path: string, doc: ^svg.Document, background: Maybe(svg.Color)) {
	app^ = {
		path             = path,
		doc              = doc,
		background       = background,
		view             = DEFAULT_VIEW,
		last_interaction = time.time_add(time.now(), -ZOOM_SETTLE_DELAY),
	}
	watcher_start(&app.watcher, path)
}

app_destroy :: proc(app: ^App) {
	watcher_stop(&app.watcher)
	if tex, ok := app.texture.?; ok {rl.UnloadTexture(tex)}
	svg.destroy(app.doc)
	delete(app.reload_error)
}

// On a file change, tries to reload the SVG. A failed reload keeps showing
// the last-good document instead of crashing. The current pan/zoom is kept
// across reloads so you can watch a zoomed-in detail update as you edit.
@(private = "file")
poll_reload :: proc(app: ^App) {
	if !watcher_poll(&app.watcher) {return}

	doc, err := svg.load(app.path)
	if err != "" {
		delete(app.reload_error)
		app.reload_error = fmt.aprintf("reload failed: %s", err)
		app.reload_error_at = time.now()
		fmt.eprintfln("warning: %s", app.reload_error)
		delete(err)
		return
	}
	svg.destroy(app.doc)
	app.doc = doc
	app.generation += 1
	delete(app.reload_error)
	app.reload_error = ""
}

app_frame :: proc(app: ^App) {
	poll_reload(app)

	rl.BeginDrawing()
	defer rl.EndDrawing()
	rl.ClearBackground(WINDOW_BACKGROUND)

	avail := Vec2{f64(rl.GetScreenWidth()), f64(rl.GetScreenHeight())}
	if avail.x <= 0 || avail.y <= 0 {return}

	svg_size := Vec2{max(app.doc.width, 1), max(app.doc.height, 1)}
	view_refit(&app.view, svg_size, avail)

	// Recomputed per frame rather than stored: a live-reloaded document can
	// move its geometry and so change the ceiling underneath a view the user
	// has already zoomed in. Pull them back to the new ceiling when that
	// happens, keeping the canvas center fixed.
	max_scale := max_scale_for_extent(app.doc.coord_extent, MAX_COORD_MAGNITUDE, MIN_SCALE)
	if app.view.scale > max_scale {
		view_zoom(&app.view, max_scale / app.view.scale, avail / 2, MIN_SCALE, max_scale)
	}

	handle_input(app, avail, svg_size, max_scale)

	// `avail`/`view.scale` are in screen points, but the texture needs to be
	// sized in physical pixels or it comes out under-resolved (and blurrily
	// upscaled) on HiDPI displays, where the framebuffer is larger.
	pixels_per_point := max(f64(rl.GetRenderWidth()) / avail.x, 1)
	raster_scale := app.view.scale * pixels_per_point
	whole_doc_limit := f64(min(MAX_TEXTURE_SIDE, MAX_RASTER_DIMENSION))

	// Ideal, uncapped resolution needed to rasterize the *whole* document
	// crisply at the current zoom.
	ideal := svg_size * raster_scale

	key: Raster_Key
	svg_rect: svg.Rect
	if ideal.x <= whole_doc_limit && ideal.y <= whole_doc_limit {
		// Fits within the cap: rasterize the whole document. Panning and
		// zooming then just reposition/rescale this same texture (cheap),
		// since its content doesn't depend on either.
		key.px_width = clamp(int(math.round(ideal.x)), 1, int(whole_doc_limit))
		key.px_height = clamp(int(math.round(ideal.y)), 1, int(whole_doc_limit))
		svg_rect = {{0, 0}, svg_size}
	} else {
		// Too zoomed in for the whole document to stay crisp within the
		// resolution cap. Rasterize just the visible viewport at full
		// resolution instead of downsampling the whole document into a
		// capped-size texture, which would look blurry.
		//
		// One texel per physical pixel of canvas. Only MAX_TEXTURE_SIDE
		// bounds this: applying MAX_RASTER_DIMENSION as well would
		// under-resolve the texture and stretch it back over a larger window,
		// reintroducing exactly the blur this path exists to avoid.
		key.px_width = clamp(int(math.round(avail.x * pixels_per_point)), 1, MAX_TEXTURE_SIDE)
		key.px_height = clamp(int(math.round(avail.y * pixels_per_point)), 1, MAX_TEXTURE_SIDE)
		min_pt := -app.view.offset / app.view.scale
		svg_rect = {min_pt, min_pt + avail / app.view.scale}
		key.has_crop = true
		key.crop = svg_rect
	}
	key.generation = app.generation

	// The draw rect below always reflects the live scale/offset (cheap: it's
	// just a GPU-side stretch/reposition of whatever texture we already
	// have), so it's safe to defer the actual re-rasterize until the pan/zoom
	// gesture settles.
	settled := time.since(app.last_interaction) >= ZOOM_SETTLE_DELAY
	if last, ok := app.last_key.?; !ok || last != key {
		if app.texture == nil || settled {
			pm: svg.Pixmap
			if key.has_crop {
				pm = svg.rasterize_region(app.doc, svg_rect, key.px_width, key.px_height, app.background)
			} else {
				pm = svg.rasterize(app.doc, key.px_width, key.px_height, app.background)
			}
			upload_texture(app, pm)
			svg.pixmap_destroy(&pm)
			app.last_key = key
			app.texture_rect = svg_rect
		}
	}

	if tex, ok := app.texture.?; ok {
		// Map the SVG-space rect the texture depicts through the *live*
		// scale/offset, so it stays correctly placed even while a fresh
		// rasterize is deferred mid-gesture. Kept in f64 until the very end:
		// the large magnitudes of `offset` and `texture_rect.min * scale`
		// mostly cancel out, so doing that in f64 avoids reintroducing the
		// precision loss the rest of this module works around. Only the final
		// result, always modest and screen-sized, is downcast for raylib.
		r := app.texture_rect
		image_min := app.view.offset + r.min * app.view.scale
		image_size := (r.max - r.min) * app.view.scale
		rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
		rl.DrawTexturePro(
			tex,
			{0, 0, f32(tex.width), f32(tex.height)},
			{f32(image_min.x), f32(image_min.y), f32(image_size.x), f32(image_size.y)},
			{0, 0},
			0,
			rl.WHITE,
		)
		rl.EndBlendMode()
	}

	// Reload errors only go to stderr otherwise, which is invisible when the
	// viewer is launched from an editor/script rather than a visible terminal.
	if app.reload_error != "" && time.since(app.reload_error_at) < ERROR_BANNER_DURATION {
		rl.DrawRectangle(0, 0, i32(avail.x), 30, {178, 34, 34, 230})
		msg := strings.clone_to_cstring(app.reload_error, context.temp_allocator)
		rl.DrawText(msg, 10, 5, 20, rl.WHITE)
	}
}

// Mouse drag pans, the wheel zooms around the cursor, arrow keys pan, +/-
// zoom around the canvas center, R (or 0) resets to fit-to-window, and Q
// quits.
@(private = "file")
handle_input :: proc(app: ^App, avail, svg_size: Vec2, max_scale: f64) {
	now := time.now()

	any_button_down := rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.MIDDLE) || rl.IsMouseButtonDown(.RIGHT)
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.MIDDLE) || rl.IsMouseButtonPressed(.RIGHT) {
		app.dragging = true
	}
	if !any_button_down {app.dragging = false}
	if app.dragging {
		if d := rl.GetMouseDelta(); d != {0, 0} {
			view_pan(&app.view, {f64(d.x), f64(d.y)})
			app.last_interaction = now
		}
	}

	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		mouse := rl.GetMousePosition()
		factor := math.exp(f64(wheel) * SCROLL_ZOOM_PER_NOTCH)
		view_zoom(&app.view, factor, {f64(mouse.x), f64(mouse.y)}, MIN_SCALE, max_scale)
		app.last_interaction = now
	}

	if rl.IsKeyPressed(.Q) {app.quit = true}

	if rl.IsKeyPressed(.R) || rl.IsKeyPressed(.ZERO) || rl.IsKeyPressed(.KP_0) {
		app.view = DEFAULT_VIEW
		view_refit(&app.view, svg_size, avail)
		return
	}

	dir: Vec2
	if rl.IsKeyDown(.LEFT) {dir.x += 1}
	if rl.IsKeyDown(.RIGHT) {dir.x -= 1}
	if rl.IsKeyDown(.UP) {dir.y += 1}
	if rl.IsKeyDown(.DOWN) {dir.y -= 1}
	if dir != {0, 0} {
		dir /= math.sqrt(dir.x * dir.x + dir.y * dir.y)
		view_pan(&app.view, dir * KEY_PAN_SPEED * f64(rl.GetFrameTime()))
		app.last_interaction = now
	}

	pressed :: proc(key: rl.KeyboardKey) -> bool {
		return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
	}
	zoom_in := pressed(.EQUAL) || pressed(.KP_ADD)
	zoom_out := pressed(.MINUS) || pressed(.KP_SUBTRACT)
	if zoom_in || zoom_out {
		factor := zoom_in ? KEY_ZOOM_STEP : 1.0 / KEY_ZOOM_STEP
		view_zoom(&app.view, factor, avail / 2, MIN_SCALE, max_scale)
		app.last_interaction = now
	}
}

@(private = "file")
upload_texture :: proc(app: ^App, pm: svg.Pixmap) {
	if tex, ok := app.texture.?; ok {
		if int(tex.width) == pm.width && int(tex.height) == pm.height {
			rl.UpdateTexture(tex, raw_data(pm.pixels))
			return
		}
		rl.UnloadTexture(tex)
	}
	image := rl.Image {
		data    = raw_data(pm.pixels),
		width   = i32(pm.width),
		height  = i32(pm.height),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	tex := rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(tex, .BILINEAR)
	app.texture = tex
}
