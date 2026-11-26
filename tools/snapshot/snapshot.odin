#+build !windows
package snapshot

// Renders the voz window to PNGs off Windows (stb_truetype text) for design review:
//   odin run tools/snapshot -- <out_dir> <regular.ttf> <semibold.ttf> [scale]

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"

import "../../dsp"
import "../../ui"

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: snapshot <out_dir> <regular.ttf> <semibold.ttf> [scale]")
		os.exit(1)
	}
	out_dir := os.args[1]
	regular, ok1 := os.read_entire_file(os.args[2], context.allocator)
	semibold, ok2 := os.read_entire_file(os.args[3], context.allocator)
	if ok1 != nil || ok2 != nil { fmt.eprintln("can't read fonts"); os.exit(1) }
	scale: f32 = 2
	if len(os.args) > 4 do scale, _ = strconv.parse_f32(os.args[4])

	Shot :: struct { name: string, dark: bool, page: ui.Page, popup: ui.Popup, hover: [2]f32 }
	shots := []Shot{
		{"main-dark", true, .Main, .None, {-1, -1}},
		{"main-light", false, .Main, .None, {-1, -1}},
		{"advanced-dark", true, .Advanced, .None, {-1, -1}},
		{"popup-light", false, .Main, .Playback, {400, 140}},
	}
	for shot in shots {
		w, h := i32(ui.PANEL_W * scale + 0.5), i32(ui.PANEL_H * scale + 0.5)
		pixels := make([]u32, w * h)
		canvas := ui.Canvas{px = raw_data(pixels), w = w, h = h}
		ui.canvas_full_clip(&canvas)

		gc := new(ui.Glyph_Cache)
		fonts: ui.Fonts
		ui.font_init_stb(&fonts.body, 1, regular, 14 * scale)
		ui.font_init_stb(&fonts.strong, 2, semibold, 14 * scale)
		ui.font_init_stb(&fonts.caption, 3, regular, 12 * scale)
		ui.font_init_stb(&fonts.small, 4, regular, 10 * scale)
		ui.font_init_stb(&fonts.small_strong, 5, semibold, 10 * scale)

		accent := shot.dark ? ui.DEFAULT_ACCENT_DARK : ui.DEFAULT_ACCENT_LIGHT
		u := ui.Ui{c = &canvas, gc = gc, f = &fonts, th = ui.theme_make(shot.dark, accent), s = scale, mx = -1, my = -1}
		panel: ui.Panel
		ui.panel_init(&panel)
		panel.page, panel.popup = shot.page, shot.popup

		params := dsp.params_default()
		capture := []string{"Default", "Microphone (USB Audio Device — Yeti Stereo Microphone)", "Headset Microphone (Arctis 7)", "Line In (Realtek(R) Audio)"}
		playback := []string{"VB-Cable (auto)", "CABLE Input (VB-Audio Virtual Cable)", "Speakers (Realtek(R) Audio)", "Headphones (Arctis 7 Game)"}
		model := ui.Panel_Model{
			params = &params, capture = capture, playback = playback,
			capture_sel = 1, playback_sel = 0,
			status = "Running  ·  48 kHz  ·  10 ms", status_kind = .Ok,
		}
		// Settle the meter on a talking level.
		for i in 0 ..< 40 {
			model.stats = {in_peak = 0.28, out_peak = 0.33, gate_gain = 1, comp_gr_db = 6, vad = 0.93}
			if i == 10 do model.stats.in_peak = 0.45 // a peak for the hold tick
			model.stats_new, model.dt = true, 1.0 / 30
			ui.panel_frame(&u, &panel, &model)
		}
		// Cost: full redraw vs. a meter tick (clip = meter card only).
		N :: 50
		t0 := time.tick_now()
		for _ in 0 ..< N do ui.panel_frame(&u, &panel, &model)
		full := time.duration_milliseconds(time.tick_since(t0)) / N
		canvas.clip = ui.panel_meter_clip(&u)
		t0 = time.tick_now()
		for _ in 0 ..< N do ui.panel_frame(&u, &panel, &model)
		tick := time.duration_milliseconds(time.tick_since(t0)) / N
		ui.canvas_full_clip(&canvas)
		fmt.printf("%s @%.1fx: full frame %.2f ms, meter tick %.2f ms\n", shot.name, scale, full, tick)

		u.mx, u.my = shot.hover.x, shot.hover.y
		model.stats_new = false
		ui.panel_frame(&u, &panel, &model)

		rgba := make([]u8, w * h * 4)
		for px, i in pixels {
			rgba[i * 4 + 0] = u8(px >> 16)
			rgba[i * 4 + 1] = u8(px >> 8)
			rgba[i * 4 + 2] = u8(px)
			rgba[i * 4 + 3] = 255
		}
		path := strings.clone_to_cstring(fmt.tprintf("%s/voz-%s.png", out_dir, shot.name))
		stbi.write_png(path, w, h, 4, raw_data(rgba), w * 4)
	}
}
