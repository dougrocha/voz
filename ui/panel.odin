#+build !windows
package ui

import "core:math"
import "core:strconv"

import "../dsp"

// The voz window contents. Portable: the platform layer feeds input + a model and presents
// the canvas. Main page = meter + essentials; Advanced page replaces the right column.

PANEL_W :: 640
PANEL_H :: 490

METER_DB_MIN :: f32(-60)

Page :: enum u8 { Main, Advanced }
Popup :: enum u8 { None, Capture, Playback }

Ctl :: enum u32 {
	None,
	Comp_Line, Gate_Line,
	Capture, Playback,
	NS_On, NS_Strength,
	Gate_On, Comp_On, Bypass,
	Input_Gain, Ratio, Makeup, Output_Gain,
	Advanced, Back,
	Highpass_On, Highpass_Hz,
	EQ0, EQ1, EQ2, EQ3,
	Gate_Release, Comp_Attack, Comp_Release,
	Gate_Voice, Voice_Thresh,
	Popup_Items = 1000, // + item index
}

Panel :: struct {
	page:   Page,
	popup:  Popup,
	scroll: int,
	// Meter display state (dB), smoothed in the UI so the audio side stays dumb.
	in_db, out_db, gr_db: f32,
	peak_db, peak_hold:   f32,
	vad:          f32,  // < 0: RNNoise not running
	ns_suspended: bool, // overload guard tripped (shown until the user re-enables)
}

Panel_Model :: struct {
	params:       ^dsp.Params,
	capture:      []string, // [0] = "Default"
	playback:     []string, // [0] = "VB-Cable (auto)"
	capture_sel:  int,
	playback_sel: int,
	stats:        dsp.Chain_Stats,
	stats_new:    bool, // stats came from a fresh meter read (advance the meter)
	dt:           f32,
	status:       string,
	status_kind:  Status_Kind,
}

Panel_Result :: struct {
	params:   bool, // params changed: publish + save
	capture:  int,  // new selection or -1
	playback: int,
}

panel_init :: proc "contextless" (p: ^Panel) {
	p.in_db, p.out_db, p.peak_db = METER_DB_MIN, METER_DB_MIN, METER_DB_MIN
	p.vad = -1
}

// Physical rect of the meter: the only region redrawn on meter ticks.
panel_meter_clip :: proc "contextless" (ui: ^Ui) -> Clip {
	r := S(ui, meter_card())
	return {i32(r.x) - 2, i32(r.y) - 2, i32(r.x + r.w) + 3, i32(r.y + r.h) + 3}
}

@(private) meter_card :: #force_inline proc "contextless" () -> Rect { return {16, 16, 160, PANEL_H - 32} }

panel_frame :: proc(ui: ^Ui, p: ^Panel, m: ^Panel_Model) -> (res: Panel_Result) {
	res.capture, res.playback = -1, -1
	ui_begin(ui)
	th := &ui.th
	fill_rect(ui.c, S(ui, {0, 0, PANEL_W, PANEL_H}), th.bg)

	ui.blocked = p.popup != .None
	if meter(ui, p, m) do res.params = true

	RX :: 16 + 160 + 12
	RW :: PANEL_W - RX - 16
	cap_anchor  := Rect{RX + 112, 16 + 10, RW - 112 - 14, 32}
	play_anchor := Rect{RX + 112, 16 + 50, RW - 112 - 14, 32}

	switch p.page {
	case .Main:
		res.params |= page_main(ui, p, m, RX, RW, cap_anchor, play_anchor)
	case .Advanced:
		res.params |= page_advanced(ui, p, m, RX, RW)
	}

	// Status line. An overload suspension outranks "Running".
	sy: f32 = PANEL_H - 22
	status, kind := m.status, m.status_kind
	if p.ns_suspended && kind == .Ok {
		status, kind = "Noise suppression paused: CPU overloaded. Toggle it to retry.", .Warn
	}
	dot := kind == .Ok ? th.green : (kind == .Warn ? th.amber : th.red)
	fill_circle(ui.c, (RX + 20) * ui.s, sy * ui.s, 4 * ui.s, dot)
	label(ui, &ui.f.caption, RX + 32, sy, status, th.sub, .Left, RW - 40)

	// Popup last: drawn on top, owns input while open.
	if p.popup != .None {
		items := p.popup == .Capture ? m.capture : m.playback
		sel := p.popup == .Capture ? m.capture_sel : m.playback_sel
		anchor := p.popup == .Capture ? cap_anchor : play_anchor
		picked, close := list_popup(ui, u32(Ctl.Popup_Items), anchor, items, sel, &p.scroll, PANEL_H - 8)
		if picked >= 0 && picked != sel {
			if p.popup == .Capture do res.capture = picked
			else do res.playback = picked
		}
		if close do p.popup = .None
	}
	ui.blocked = false
	ui_end(ui)
	return
}

// Closes a popup / leaves Advanced. Returns false if there was nothing to close (Esc hides).
panel_escape :: proc "contextless" (p: ^Panel) -> bool {
	if p.popup != .None { p.popup = .None; return true }
	if p.page != .Main { p.page = .Main; return true }
	return false
}

// ---------------------------------------------------------------------------

@(private)
page_main :: proc(ui: ^Ui, p: ^Panel, m: ^Panel_Model, RX, RW: f32, cap_anchor, play_anchor: Rect) -> bool {
	th := &ui.th
	pr := m.params
	changed := false
	y: f32 = 16

	card(ui, {RX, y, RW, 92})
	label(ui, &ui.f.body, RX + 16, cap_anchor.y + 16, "Microphone", th.text)
	label(ui, &ui.f.body, RX + 16, play_anchor.y + 16, "Output", th.text)
	if dropdown(ui, u32(Ctl.Capture), cap_anchor, m.capture[m.capture_sel]) { p.popup = .Capture; p.scroll = max(m.capture_sel - 3, 0) }
	if dropdown(ui, u32(Ctl.Playback), play_anchor, m.playback[m.playback_sel]) { p.popup = .Playback; p.scroll = max(m.playback_sel - 3, 0) }
	y += 92 + 8

	// Noise suppression: toggle + strength on one row.
	card(ui, {RX, y, RW, 48})
	if toggle(ui, u32(Ctl.NS_On), RX + 16, y + 24, "Noise suppression", &pr.ns_on) {
		changed = true
		if pr.ns_on do p.ns_suspended = false // re-enabling clears the overload notice
	}
	ns_cy, ns_x := y + 24, RX + 206
	changed |= slider(ui, u32(Ctl.NS_Strength), {ns_x, ns_cy - 12, RX + RW - 76 - ns_x, 24}, &pr.ns_strength, 0, 1, 0.05, pr.ns_on)
	pct_num: [16]u8
	pct: [20]u8
	pn := copy(pct[:], num_text(pct_num[:], pr.ns_strength * 100, 0))
	pn += copy(pct[pn:], "%")
	label(ui, &ui.f.body, RX + RW - 16, ns_cy, string(pct[:pn]), pr.ns_on ? th.sub : th.disabled, .Right)
	y += 48 + 8

	card(ui, {RX, y, RW, 48})
	changed |= toggle(ui, u32(Ctl.Gate_On), RX + 16, y + 24, "Gate", &pr.gate_on)
	changed |= toggle(ui, u32(Ctl.Comp_On), RX + 128, y + 24, "Compressor", &pr.comp_on)
	changed |= toggle(ui, u32(Ctl.Bypass), RX + 286, y + 24, "Bypass", &pr.bypass)
	y += 48 + 8

	card(ui, {RX, y, RW, 164})
	changed |= slider_row(ui, .Input_Gain, RX, RW, y + 24, "Input gain", &pr.input_gain_db, -24, 24, 0.5, " dB")
	changed |= slider_row(ui, .Ratio, RX, RW, y + 62, "Ratio", &pr.comp_ratio, 1, 10, 0.1, " : 1", pr.comp_on)
	changed |= slider_row(ui, .Makeup, RX, RW, y + 100, "Makeup", &pr.comp_makeup_db, 0, 24, 0.5, " dB", pr.comp_on)
	changed |= slider_row(ui, .Output_Gain, RX, RW, y + 138, "Output gain", &pr.output_gain_db, -24, 24, 0.5, " dB")
	y += 164 + 8

	if nav_card(ui, u32(Ctl.Advanced), {RX, y, RW, 48}, "Advanced", "EQ, high-pass, timing") {
		p.page = .Advanced
	}
	return changed
}

@(private)
page_advanced :: proc(ui: ^Ui, p: ^Panel, m: ^Panel_Model, RX, RW: f32) -> bool {
	pr := m.params
	changed := false
	if back_header(ui, u32(Ctl.Back), RX, 32, "Advanced") do p.page = .Main

	ROW :: 32
	y: f32 = 56
	card(ui, {RX, y, RW, 6 * ROW + 12})
	cy := y + 6 + ROW / 2
	changed |= toggle(ui, u32(Ctl.Highpass_On), RX + 16, cy, "High-pass filter", &pr.highpass_on); cy += ROW
	changed |= slider_row(ui, .Highpass_Hz, RX, RW, cy, "Cutoff", &pr.highpass_hz, 20, 300, 5, " Hz", pr.highpass_on); cy += ROW
	for i in 0 ..< dsp.EQ_BANDS {
		b := &pr.eq[i]
		name: [24]u8
		changed |= slider_row(ui, Ctl(int(Ctl.EQ0) + i), RX, RW, cy, eq_label(name[:], b), &b.gain_db, -12, 12, 0.5, " dB", b.kind != .Off)
		cy += ROW
	}
	y += 6 * ROW + 12 + 8

	card(ui, {RX, y, RW, 5 * ROW + 12})
	cy = y + 6 + ROW / 2
	if toggle(ui, u32(Ctl.Gate_Voice), RX + 16, cy, "Voice-activated gate", &pr.gate_voice) {
		changed = true
		if pr.gate_voice do p.ns_suspended = false
	}
	cy += ROW
	changed |= slider_row(ui, .Voice_Thresh, RX, RW, cy, "Confidence", &pr.gate_voice_thresh, 0.05, 0.95, 0.05, "%", pr.gate_on && pr.gate_voice, 100); cy += ROW
	changed |= slider_row(ui, .Gate_Release, RX, RW, cy, "Gate release", &pr.gate_release_ms, 10, 1000, 10, " ms", pr.gate_on); cy += ROW
	changed |= slider_row(ui, .Comp_Attack, RX, RW, cy, "Comp attack", &pr.comp_attack_ms, 0.5, 100, 0.5, " ms", pr.comp_on); cy += ROW
	changed |= slider_row(ui, .Comp_Release, RX, RW, cy, "Comp release", &pr.comp_release_ms, 10, 1000, 10, " ms", pr.comp_on)
	return changed
}

// Label | slider | value, one row centered on cy.
@(private)
slider_row :: proc(ui: ^Ui, id: Ctl, RX, RW, cy: f32, name: string, v: ^f32, lo, hi, step: f32, unit: string, enabled := true, display_mul: f32 = 1) -> bool {
	th := &ui.th
	label(ui, &ui.f.body, RX + 16, cy, name, enabled ? th.text : th.disabled, .Left, 92)
	changed := slider(ui, u32(id), {RX + 112, cy - 12, RW - 112 - 76, 24}, v, lo, hi, step, enabled)
	num: [32]u8
	txt: [40]u8
	n := copy(txt[:], num_text(num[:], v^ * display_mul, step * display_mul < 1 ? 1 : 0))
	n += copy(txt[n:], unit)
	label(ui, &ui.f.body, RX + RW - 16, cy, string(txt[:n]), enabled ? th.sub : th.disabled, .Right)
	return changed
}

// ---------------------------------------------------------------------------
// Meter: input level (main bar), output (thin), gain reduction (from top),
// draggable compressor (red) and gate (amber) threshold lines.
// ---------------------------------------------------------------------------

@(private)
meter :: proc(ui: ^Ui, p: ^Panel, m: ^Panel_Model) -> (changed: bool) {
	th := &ui.th
	pr := m.params
	if m.stats_new do meter_advance(p, m.stats, m.dt)

	cr := meter_card()
	card(ui, cr)
	label(ui, &ui.f.strong, cr.x + 14, cr.y + 18, "Level", th.text)

	// Voice indicator: RNNoise thinks you're talking. Hidden when RNNoise isn't running.
	if p.vad >= 0 {
		vr := Rect{cr.x + cr.w - 58, cr.y + 9, 46, 18}
		talking := p.vad >= pr.gate_voice_thresh
		if talking {
			fill_rrect(ui.c, S(ui, vr), 9 * ui.s, th.green)
		} else {
			stroke_rrect(ui.c, S(ui, vr), 9 * ui.s, max(1, ui.s), th.faint)
		}
		label(ui, &ui.f.small_strong, vr.x + vr.w / 2, vr.y + vr.h / 2, "Voice", talking ? (th.dark ? rgb(0, 0, 0) : rgb(255, 255, 255)) : th.faint, .Center)
	}

	top, bot := cr.y + 36, cr.y + cr.h - 30
	ydb :: proc(top, bot, db: f32) -> f32 { return top + (bot - top) * clamp(db / METER_DB_MIN, 0, 1) }
	BX :: f32(16 + 44); BW :: f32(34)
	OX :: BX + BW + 6; OW :: f32(8)
	GX :: OX + OW + 4; GW :: f32(8)
	PX :: GX + GW + 6 // threshold pills

	for db := f32(0); db >= METER_DB_MIN; db -= 10 {
		num: [8]u8
		label(ui, &ui.f.small, BX - 8, ydb(top, bot, db), num_text(num[:], db, 0), th.faint, .Right)
	}

	// Tracks.
	fill_rrect(ui.c, S(ui, {BX, top, BW, bot - top}), 4 * ui.s, th.meter_bg)
	fill_rrect(ui.c, S(ui, {OX, top, OW, bot - top}), 3 * ui.s, th.meter_bg)
	fill_rrect(ui.c, S(ui, {GX, top, GW, bot - top}), 3 * ui.s, th.meter_bg)

	// Gated zone below the gate line.
	gy := ydb(top, bot, pr.gate_thresh_db)
	if pr.gate_on {
		fill_rrect(ui.c, S(ui, {BX, gy, BW, bot - gy}), 4 * ui.s, th.gated)
		hatch(ui.c, S(ui, {BX + 2, gy + 1, BW - 4, bot - gy - 3}), 6 * ui.s, 1 * ui.s, with_alpha(th.faint, 0.25))
	}

	// Input bar: green; red above the compressor threshold; dimmed below the gate line.
	ly := ydb(top, bot, p.in_db)
	cy := ydb(top, bot, pr.comp_thresh_db)
	inner := Rect{BX + 3, ly, BW - 6, bot - 3 - ly}
	if inner.h > 0 {
		fill_rrect(ui.c, S(ui, inner), 3 * ui.s, th.green)
		if pr.comp_on && ly < cy do fill_rrect(ui.c, S(ui, {inner.x, ly, inner.w, cy - ly}), 3 * ui.s, th.red)
		if pr.gate_on && ly < gy {
			fill_rect(ui.c, S(ui, {inner.x, gy, inner.w, bot - 3 - gy}), with_alpha(th.gated, 0.55))
		}
	}
	// Peak hold tick.
	if p.peak_db > METER_DB_MIN + 0.5 {
		py := ydb(top, bot, p.peak_db)
		fill_rrect(ui.c, S(ui, {BX + 3, py - 1, BW - 6, 2}), 1 * ui.s, th.text)
	}
	// Output (thin) and gain reduction (down from the top, 0..30 dB full height... scaled like dB).
	oy := ydb(top, bot, p.out_db)
	if bot - 1 - oy > 0 do fill_rrect(ui.c, S(ui, {OX + 1, oy, OW - 2, bot - 1 - oy}), 2 * ui.s, th.accent)
	grh := (bot - top) * clamp(p.gr_db / -METER_DB_MIN, 0, 1)
	if grh > 0.5 do fill_rrect(ui.c, S(ui, {GX + 1, top + 1, GW - 2, grh}), 2 * ui.s, th.red)

	// Threshold lines. Gate first so the compressor line wins when they overlap.
	changed |= threshold(ui, .Gate_Line, &pr.gate_thresh_db, top, bot, BX, PX, th.amber, pr.gate_on)
	changed |= threshold(ui, .Comp_Line, &pr.comp_thresh_db, top, bot, BX, PX, th.red, pr.comp_on)

	// Legend.
	lg := cr.y + cr.h - 15
	fill_rrect(ui.c, S(ui, {cr.x + 14, lg - 4, 8, 8}), 2 * ui.s, th.red)
	label(ui, &ui.f.small, cr.x + 26, lg, "Comp", th.sub)
	fill_rrect(ui.c, S(ui, {cr.x + 70, lg - 4, 8, 8}), 2 * ui.s, th.amber)
	label(ui, &ui.f.small, cr.x + 82, lg, "Gate", th.sub)
	fill_rrect(ui.c, S(ui, {cr.x + 118, lg - 4, 8, 8}), 2 * ui.s, th.accent)
	label(ui, &ui.f.small, cr.x + 130, lg, "Out", th.sub)
	return
}

// A horizontal draggable line + value pill. Disabled stages draw faded and still drag.
@(private)
threshold :: proc(ui: ^Ui, id: Ctl, db: ^f32, top, bot, bx, px: f32, col: Color, on: bool) -> bool {
	y := top + (bot - top) * clamp(db^ / METER_DB_MIN, 0, 1)
	PW, PH :: f32(42), f32(20)
	hit := Rect{bx - 4, y - 7, px + PW - bx + 4, 14}
	it := interact(ui, u32(id), hit)
	if it.hover || it.held do ui.cursor = .Resize_NS

	changed := false
	if it.held {
		v := clamp(math.round((ui.my - top) / (bot - top) * METER_DB_MIN * 2) / 2, METER_DB_MIN, 0)
		if v != db^ { db^ = v; changed = true; y = top + (bot - top) * (v / METER_DB_MIN) }
	} else if it.hover && ui.wheel != 0 {
		db^ = clamp(db^ + ui.wheel * 0.5, METER_DB_MIN, 0)
		changed = true
	}

	c := on ? col : with_alpha(col, 0.4)
	thick: f32 = it.hover || it.held ? 3 : 2
	fill_rect(ui.c, S(ui, {bx - 4, y - thick / 2, px - bx + 4, thick}), c)
	fill_rrect(ui.c, S(ui, {px, y - PH / 2, PW, PH}), PH / 2 * ui.s, c)
	num: [16]u8
	is_whole := db^ == math.floor(db^)
	text_col := ui.th.dark && id == .Gate_Line ? rgb(0, 0, 0) : rgb(255, 255, 255)
	label(ui, &ui.f.small_strong, px + PW / 2, y, num_text(num[:], db^, is_whole ? 0 : 1), text_col, .Center)
	return changed
}

// Fast attack, ~24 dB/s fall, 1 s peak hold.
@(private)
meter_advance :: proc(p: ^Panel, s: dsp.Chain_Stats, dt: f32) {
	to_db :: proc(x: f32) -> f32 { return x > 0.001 ? max(20 * math.log10(x), METER_DB_MIN) : METER_DB_MIN }
	fall := 24 * dt
	in_db := to_db(s.in_peak)
	out_db := to_db(s.out_peak)
	p.in_db = max(in_db, p.in_db - fall)
	p.out_db = max(out_db, p.out_db - fall)
	p.gr_db = max(s.comp_gr_db, p.gr_db - 2 * fall)
	p.vad = s.vad
	if s.ns_suspended do p.ns_suspended = true
	if in_db >= p.peak_db {
		p.peak_db, p.peak_hold = in_db, 1
	} else {
		p.peak_hold -= dt
		if p.peak_hold <= 0 do p.peak_db = max(p.peak_db - fall, METER_DB_MIN)
	}
}

// ---------------------------------------------------------------------------

// Fixed-point text without strconv's forced '+' sign.
num_text :: proc(buf: []u8, v: f32, decimals: int) -> string {
	s := strconv.write_float(buf, f64(v), 'f', decimals, 32)
	return len(s) > 0 && s[0] == '+' ? s[1:] : s
}

eq_label :: proc(buf: []u8, b: ^dsp.EQ_Band) -> string {
	num: [16]u8
	hz := b.freq_hz
	n := 0
	if hz >= 1000 {
		n += copy(buf[n:], num_text(num[:], hz / 1000, hz < 10000 && math.mod(hz, 1000) != 0 ? 1 : 0))
		n += copy(buf[n:], " kHz")
	} else {
		n += copy(buf[n:], num_text(num[:], hz, 0))
		n += copy(buf[n:], " Hz")
	}
	switch b.kind {
	case .Low_Shelf:  n += copy(buf[n:], " low")
	case .High_Shelf: n += copy(buf[n:], " high")
	case .Peaking, .Off:
	}
	return string(buf[:n])
}
