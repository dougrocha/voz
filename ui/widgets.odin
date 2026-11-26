#+build !windows
package ui

import "core:math"

// Immediate-mode widgets in the WinUI 3 (Fluent) style. Layout is in logical units (96 DPI);
// `s` scales to physical pixels at draw time. One widget may be `active` (pressed/dragging).

Theme :: struct {
	dark:        bool,
	bg:          Color, // window (Mica base)
	card:        Color,
	card_line:   Color,
	ctrl:        Color, // control fill (dropdown, toggle-off knob track)
	ctrl_hover:  Color,
	ctrl_press:  Color,
	ctrl_line:   Color,
	popup:       Color,
	popup_line:  Color,
	text:        Color,
	sub:         Color, // secondary text
	faint:       Color, // tertiary text, ticks
	disabled:    Color,
	accent:      Color,
	accent_hover: Color,
	on_accent:   Color, // knob / text on accent
	track:       Color, // slider rail, toggle-off outline
	meter_bg:    Color,
	gated:       Color,
	green:       Color,
	red:         Color,
	amber:       Color,
	shadow:      Color,
}

// accent: the system accent variant for this mode (AccentLight2 in dark, AccentDark1 in light).
theme_make :: proc "contextless" (dark: bool, accent: Color) -> Theme {
	if dark {
		return {
			dark = true,
			bg = rgb(32, 32, 32), card = rgb(43, 43, 43), card_line = rgb(29, 29, 29),
			ctrl = rgb(55, 55, 55), ctrl_hover = rgb(61, 61, 61), ctrl_press = rgb(50, 50, 50), ctrl_line = rgb(66, 66, 66),
			popup = rgb(44, 44, 44), popup_line = rgb(70, 70, 70),
			text = rgb(255, 255, 255), sub = rgb(207, 207, 207), faint = rgb(150, 150, 150), disabled = rgb(110, 110, 110),
			accent = accent, accent_hover = mix(accent, rgb(0, 0, 0), 0.1), on_accent = rgb(0, 0, 0),
			track = rgb(154, 154, 154), meter_bg = rgb(26, 26, 26), gated = rgb(20, 20, 20),
			green = rgb(108, 203, 95), red = rgb(255, 99, 99), amber = rgb(252, 196, 25),
			shadow = Color(0x66000000),
		}
	}
	return {
		dark = false,
		bg = rgb(243, 243, 243), card = rgb(251, 251, 251), card_line = rgb(229, 229, 229),
		ctrl = rgb(255, 255, 255), ctrl_hover = rgb(249, 249, 249), ctrl_press = rgb(245, 245, 245), ctrl_line = rgb(218, 218, 218),
		popup = rgb(249, 249, 249), popup_line = rgb(222, 222, 222),
		text = rgb(27, 27, 27), sub = rgb(96, 96, 96), faint = rgb(138, 138, 138), disabled = rgb(170, 170, 170),
		accent = accent, accent_hover = mix(accent, rgb(255, 255, 255), 0.1), on_accent = rgb(255, 255, 255),
		track = rgb(135, 135, 135), meter_bg = rgb(232, 232, 232), gated = rgb(214, 214, 214),
		green = rgb(15, 123, 15), red = rgb(196, 43, 28), amber = rgb(157, 93, 0),
		shadow = Color(0x30000000),
	}
}

DEFAULT_ACCENT_DARK  :: Color(0xFF60CDFF)
DEFAULT_ACCENT_LIGHT :: Color(0xFF005FB8)

Fonts :: struct {
	body:   Font, // 14
	strong: Font, // 14 semibold
	caption: Font, // 12
	small:  Font, // 10
	small_strong: Font, // 10 semibold
}

Cursor :: enum u8 { Arrow, Resize_NS }

Ui :: struct {
	c:     ^Canvas,
	gc:    ^Glyph_Cache,
	f:     ^Fonts,
	th:    Theme,
	s:     f32, // DPI scale

	// Input for this frame, logical units. mx/my < 0 when the mouse is outside.
	mx, my:   f32,
	down:     bool, // left button held
	pressed:  bool, // went down this frame
	released: bool, // went up this frame
	wheel:    f32,  // notches, + = up

	active:   u32,  // widget holding the mouse
	blocked:  bool, // a popup owns input; base widgets don't react
	cursor:   Cursor,
}

// Logical → physical.
S :: #force_inline proc "contextless" (ui: ^Ui, r: Rect) -> Rect {
	return {r.x * ui.s, r.y * ui.s, r.w * ui.s, r.h * ui.s}
}

ui_begin :: proc "contextless" (ui: ^Ui) {
	ui.cursor = .Arrow
}

ui_end :: proc "contextless" (ui: ^Ui) {
	if ui.released || !ui.down do ui.active = 0
	ui.pressed, ui.released, ui.wheel = false, false, 0
}

Interaction :: struct { hover, held, clicked: bool }

interact :: proc "contextless" (ui: ^Ui, id: u32, r: Rect) -> (it: Interaction) {
	inside := !ui.blocked && rect_contains(r, ui.mx, ui.my)
	it.hover = inside && (ui.active == 0 || ui.active == id)
	if it.hover && ui.pressed do ui.active = id
	it.held = ui.active == id && ui.down
	it.clicked = ui.active == id && ui.released && inside
	return
}

// ---------------------------------------------------------------------------

card :: proc(ui: ^Ui, r: Rect) {
	p := S(ui, r)
	fill_rrect(ui.c, p, 8 * ui.s, ui.th.card)
	stroke_rrect(ui.c, p, 8 * ui.s, max(1, ui.s), ui.th.card_line)
}

label :: proc(ui: ^Ui, f: ^Font, x, cy: f32, s: string, col: Color, align := Align.Left, max_w: f32 = 0) {
	draw_label(ui.c, ui.gc, f, x * ui.s, cy * ui.s, s, col, align, max_w * ui.s)
}

// Horizontal slider across r (thumb travels inside r). Returns true when *v changed.
slider :: proc(ui: ^Ui, id: u32, r: Rect, v: ^f32, lo, hi, step: f32, enabled := true) -> bool {
	th := &ui.th
	it: Interaction
	if enabled do it = interact(ui, id, r)
	THUMB :: 10
	x0, x1 := r.x + THUMB, r.x + r.w - THUMB
	cy := r.y + r.h * 0.5

	changed := false
	if it.held {
		t := clamp((ui.mx - x0) / (x1 - x0), 0, 1)
		nv := lo + math.round(t * (hi - lo) / step) * step
		if nv != v^ { v^ = nv; changed = true }
	} else if it.hover && ui.wheel != 0 {
		nv := clamp(v^ + ui.wheel * step, lo, hi)
		if nv != v^ { v^ = nv; changed = true }
	}

	t := clamp((v^ - lo) / (hi - lo), 0, 1)
	tx := x0 + (x1 - x0) * t
	rail := enabled ? th.track : th.disabled
	fill := enabled ? th.accent : th.disabled
	fill_rrect(ui.c, S(ui, {x0, cy - 2, x1 - x0, 4}), 2 * ui.s, rail)
	fill_rrect(ui.c, S(ui, {x0, cy - 2, tx - x0, 4}), 2 * ui.s, fill)

	// Thumb: control-colored disc with a ring, accent dot that grows on hover, shrinks on press.
	fill_circle(ui.c, tx * ui.s, cy * ui.s, THUMB * ui.s, th.ctrl)
	stroke_rrect(ui.c, S(ui, {tx - THUMB, cy - THUMB, 2 * THUMB, 2 * THUMB}), THUMB * ui.s, max(1, ui.s), th.ctrl_line)
	dot: f32 = it.held ? 5 : (it.hover ? 7 : 6)
	fill_circle(ui.c, tx * ui.s, cy * ui.s, dot * ui.s, fill)
	return changed
}

// ToggleSwitch with its label to the right. Returns true when *v flipped.
toggle :: proc(ui: ^Ui, id: u32, x, cy: f32, text: string, v: ^bool) -> bool {
	th := &ui.th
	TW, TH :: 40, 20
	lw := text_width(ui.gc, &ui.f.body, text) / ui.s
	it := interact(ui, id, {x, cy - 16, TW + 12 + lw, 32})
	if it.clicked do v^ = !v^

	pill := S(ui, {x, cy - TH / 2, TW, TH})
	knob: f32 = it.held ? 7 : (it.hover ? 7 : 6)
	if v^ {
		fill_rrect(ui.c, pill, TH / 2 * ui.s, it.hover ? th.accent_hover : th.accent)
		fill_circle(ui.c, (x + TW - 10) * ui.s, cy * ui.s, knob * ui.s, th.on_accent)
	} else {
		if it.hover do fill_rrect(ui.c, pill, TH / 2 * ui.s, th.ctrl_hover)
		stroke_rrect(ui.c, pill, TH / 2 * ui.s, max(1, ui.s), th.sub)
		fill_circle(ui.c, (x + 10) * ui.s, cy * ui.s, (knob - 1) * ui.s, th.sub)
	}
	label(ui, &ui.f.body, x + TW + 12, cy, text, th.text)
	return it.clicked
}

// Closed ComboBox. Returns true when clicked (caller opens its popup).
dropdown :: proc(ui: ^Ui, id: u32, r: Rect, text: string) -> bool {
	th := &ui.th
	it := interact(ui, id, r)
	p := S(ui, r)
	fill_rrect(ui.c, p, 4 * ui.s, it.held ? th.ctrl_press : (it.hover ? th.ctrl_hover : th.ctrl))
	stroke_rrect(ui.c, p, 4 * ui.s, max(1, ui.s), th.ctrl_line)
	label(ui, &ui.f.body, r.x + 11, r.y + r.h * 0.5, text, th.text, .Left, r.w - 44)
	chevron_down(ui.c, (r.x + r.w - 18) * ui.s, (r.y + r.h * 0.5) * ui.s, 4 * ui.s, 1.2 * ui.s, th.sub)
	return it.clicked
}

// Settings-style card row that navigates somewhere. Returns true when clicked.
nav_card :: proc(ui: ^Ui, id: u32, r: Rect, title, detail: string) -> bool {
	th := &ui.th
	it := interact(ui, id, r)
	p := S(ui, r)
	fill_rrect(ui.c, p, 8 * ui.s, it.hover ? mix(th.card, th.ctrl_hover, 0.6) : th.card)
	stroke_rrect(ui.c, p, 8 * ui.s, max(1, ui.s), th.card_line)
	cy := r.y + r.h * 0.5
	label(ui, &ui.f.body, r.x + 16, cy, title, th.text)
	tw := text_width(ui.gc, &ui.f.body, title) / ui.s
	label(ui, &ui.f.caption, r.x + 16 + tw + 10, cy, detail, th.sub)
	chevron_right(ui.c, (r.x + r.w - 20) * ui.s, cy * ui.s, 4.5 * ui.s, 1.2 * ui.s, th.sub)
	return it.clicked
}

// Subtle back button (chevron) with a page title. Returns true when clicked.
back_header :: proc(ui: ^Ui, id: u32, x, cy: f32, title: string) -> bool {
	th := &ui.th
	it := interact(ui, id, {x, cy - 16, 32, 32})
	if it.hover do fill_rrect(ui.c, S(ui, {x, cy - 16, 32, 32}), 4 * ui.s, th.ctrl_hover)
	chevron_left(ui.c, (x + 16) * ui.s, cy * ui.s, 5 * ui.s, 1.4 * ui.s, th.text)
	label(ui, &ui.f.strong, x + 42, cy, title, th.text)
	return it.clicked
}

// Dropdown list popup anchored under `anchor`. Call after all base widgets, with
// ui.blocked set during the base pass. Returns (picked index or -1, close).
list_popup :: proc(ui: ^Ui, id: u32, anchor: Rect, items: []string, sel: int, scroll: ^int, bottom: f32) -> (picked: int, close: bool) {
	th := &ui.th
	picked = -1
	ITEM :: 32
	PAD :: 4
	visible := clamp(int((bottom - (anchor.y + anchor.h + 4) - 2 * PAD) / ITEM), 1, len(items))
	scroll^ = clamp(scroll^, 0, len(items) - visible)
	r := Rect{anchor.x, anchor.y + anchor.h + 4, anchor.w, f32(visible) * ITEM + 2 * PAD}

	was_blocked := ui.blocked
	ui.blocked = false
	defer ui.blocked = was_blocked

	if rect_contains(r, ui.mx, ui.my) && ui.wheel != 0 {
		scroll^ = clamp(scroll^ - int(ui.wheel), 0, len(items) - visible)
	}
	if ui.pressed && !rect_contains(r, ui.mx, ui.my) {
		close = true
		ui.pressed = false // swallow: the click only dismisses
	}

	p := S(ui, r)
	fill_shadow(ui.c, {p.x, p.y + 4 * ui.s, p.w, p.h}, 8 * ui.s, 12 * ui.s, th.shadow)
	fill_rrect(ui.c, p, 8 * ui.s, th.popup)
	stroke_rrect(ui.c, p, 8 * ui.s, max(1, ui.s), th.popup_line)

	for i in 0 ..< visible {
		idx := scroll^ + i
		ir := Rect{r.x + PAD, r.y + PAD + f32(i) * ITEM, r.w - 2 * PAD, ITEM}
		it := interact(ui, id + u32(idx) + 1, ir)
		if it.hover || idx == sel {
			tint: f32 = it.held ? 0.04 : (it.hover ? 0.08 : 0.06) // subtle fill over the popup, either theme
			fill_rrect(ui.c, S(ui, rect_inset(ir, 1)), 4 * ui.s, mix(th.popup, th.text, tint))
		}
		if idx == sel do fill_rrect(ui.c, S(ui, {ir.x + 1, ir.y + ITEM / 2 - 8, 3, 16}), 1.5 * ui.s, th.accent)
		label(ui, &ui.f.body, ir.x + 12, ir.y + ITEM * 0.5, items[idx], th.text, .Left, ir.w - 20)
		if it.clicked { picked = idx; close = true }
	}
	return
}
