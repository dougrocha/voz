package tests

import "core:testing"

import "../config"
import "../dsp"

@(test)
config_round_trip :: proc(t: ^testing.T) {
	a := config.config_default()
	a.params.eq[3] = {.Low_Shelf, 120, 0.7, -3.25}
	a.params.comp_ratio = 2.5
	config.name_set(&a.devices.capture, "Microphone (USB Audio — Ünïcode)")
	config.name_set(&a.devices.playback, "CABLE Input (VB-Audio Virtual Cable)")
	a.hotkeys[.Toggle_Bypass] = {mods = 0x4006, vk = 0x42}

	buf: [config.MAX_FILE]u8
	n := config.config_format(&a, buf[:])
	testing.expect(t, n > 0)

	b: config.Config
	config.config_parse(string(buf[:n]), &b)
	testing.expectf(t, a == b, "round trip mismatch:\n%s", string(buf[:n]))
}

@(test)
config_ignores_junk_and_sanitizes :: proc(t: ^testing.T) {
	c := config.config_default()
	text := `
# comment
; also comment
unknown_key = 5
no equals sign
highpass_hz = nan
comp_ratio=0
  eq0_kind   =  high_shelf
eq1_kind = bogus
gate_thresh_db = -1e30
input_gain_db = not_a_number
`
	config.config_parse(text, &c)
	d := dsp.params_default()
	testing.expect(t, c.params.highpass_hz == 80, "NaN falls back to default")
	testing.expect(t, c.params.comp_ratio == 1, "ratio clamped to >= 1")
	testing.expect(t, c.params.eq[0].kind == .High_Shelf)
	testing.expect(t, c.params.eq[1].kind == d.eq[1].kind, "bad enum keeps value")
	testing.expect(t, c.params.gate_thresh_db == -90)
	testing.expect(t, c.params.input_gain_db == d.input_gain_db)
}

@(test)
config_format_reports_overflow :: proc(t: ^testing.T) {
	c := config.config_default()
	small: [64]u8
	testing.expect(t, config.config_format(&c, small[:]) == -1)
}
