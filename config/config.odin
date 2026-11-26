package config

import "core:strconv"
import "core:strings"

import "../dsp"

// Plain `key = value` text. Unknown keys are ignored, missing keys keep their defaults.
// Everything is table driven over byte offsets into Config, so adding a field is one line.
// No heap: parsing reads a caller-provided buffer, formatting writes into one.

MAX_FILE :: 8 * 1024
NAME_MAX :: 255

Name :: struct {
	len: u8,
	buf: [NAME_MAX]u8, // UTF-8, not NUL terminated
}

name_string :: proc "contextless" (n: ^Name) -> string { return string(n.buf[:n.len]) }

name_set :: proc "contextless" (n: ^Name, s: string) {
	n.len = u8(copy(n.buf[:], s))
}

// Match devices by name; IDs aren't stable across reboots. Empty = system default.
Device_Choice :: struct {
	capture:  Name,
	playback: Name,
}

// Hotkey plumbing: actions and bindings exist, nothing is bound by default.
Hotkey_Action :: enum u8 { Toggle_Bypass }

// Win32 RegisterHotKey modifiers (MOD_*) and virtual key. vk == 0 means unbound.
Hotkey :: struct {
	mods: u16,
	vk:   u16,
}

Config :: struct {
	params:          dsp.Params,
	devices:         Device_Choice,
	hotkeys:         [Hotkey_Action]Hotkey,
	start_minimized: bool,
	close_quits:     bool, // closing the window exits voz instead of hiding it to the tray
}

config_default :: proc "contextless" () -> Config {
	return {params = dsp.params_default(), start_minimized = false, close_quits = true} // defaults: the window opens, and closing it quits
}

// ---------------------------------------------------------------------------
// Key table
// ---------------------------------------------------------------------------

@(private) Kind :: enum u8 { Bool, F32, U16, EQ_Kind, Name }

@(private) Key :: struct {
	name:   string,
	kind:   Kind,
	offset: uintptr,
}

@(private) P   :: offset_of(Config, params)
@(private) EQ  :: P + offset_of(dsp.Params, eq)
@(private) EQS :: size_of(dsp.EQ_Band)
@(private) HK  :: offset_of(Config, hotkeys)

@(private, rodata)
KEYS := [?]Key{
	{"bypass",          .Bool, P + offset_of(dsp.Params, bypass)},
	{"input_gain_db",   .F32,  P + offset_of(dsp.Params, input_gain_db)},
	{"highpass_on",     .Bool, P + offset_of(dsp.Params, highpass_on)},
	{"highpass_hz",     .F32,  P + offset_of(dsp.Params, highpass_hz)},
	{"ns_on",           .Bool, P + offset_of(dsp.Params, ns_on)},
	{"ns_strength",     .F32,  P + offset_of(dsp.Params, ns_strength)},
	{"gate_on",         .Bool, P + offset_of(dsp.Params, gate_on)},
	{"gate_voice",      .Bool, P + offset_of(dsp.Params, gate_voice)},
	{"gate_voice_thresh", .F32, P + offset_of(dsp.Params, gate_voice_thresh)},
	{"gate_thresh_db",  .F32,  P + offset_of(dsp.Params, gate_thresh_db)},
	{"gate_floor_db",   .F32,  P + offset_of(dsp.Params, gate_floor_db)},
	{"gate_attack_ms",  .F32,  P + offset_of(dsp.Params, gate_attack_ms)},
	{"gate_hold_ms",    .F32,  P + offset_of(dsp.Params, gate_hold_ms)},
	{"gate_release_ms", .F32,  P + offset_of(dsp.Params, gate_release_ms)},

	{"eq0_kind", .EQ_Kind, EQ + 0 * EQS + offset_of(dsp.EQ_Band, kind)},
	{"eq0_hz",   .F32,     EQ + 0 * EQS + offset_of(dsp.EQ_Band, freq_hz)},
	{"eq0_q",    .F32,     EQ + 0 * EQS + offset_of(dsp.EQ_Band, q)},
	{"eq0_db",   .F32,     EQ + 0 * EQS + offset_of(dsp.EQ_Band, gain_db)},
	{"eq1_kind", .EQ_Kind, EQ + 1 * EQS + offset_of(dsp.EQ_Band, kind)},
	{"eq1_hz",   .F32,     EQ + 1 * EQS + offset_of(dsp.EQ_Band, freq_hz)},
	{"eq1_q",    .F32,     EQ + 1 * EQS + offset_of(dsp.EQ_Band, q)},
	{"eq1_db",   .F32,     EQ + 1 * EQS + offset_of(dsp.EQ_Band, gain_db)},
	{"eq2_kind", .EQ_Kind, EQ + 2 * EQS + offset_of(dsp.EQ_Band, kind)},
	{"eq2_hz",   .F32,     EQ + 2 * EQS + offset_of(dsp.EQ_Band, freq_hz)},
	{"eq2_q",    .F32,     EQ + 2 * EQS + offset_of(dsp.EQ_Band, q)},
	{"eq2_db",   .F32,     EQ + 2 * EQS + offset_of(dsp.EQ_Band, gain_db)},
	{"eq3_kind", .EQ_Kind, EQ + 3 * EQS + offset_of(dsp.EQ_Band, kind)},
	{"eq3_hz",   .F32,     EQ + 3 * EQS + offset_of(dsp.EQ_Band, freq_hz)},
	{"eq3_q",    .F32,     EQ + 3 * EQS + offset_of(dsp.EQ_Band, q)},
	{"eq3_db",   .F32,     EQ + 3 * EQS + offset_of(dsp.EQ_Band, gain_db)},

	{"comp_on",         .Bool, P + offset_of(dsp.Params, comp_on)},
	{"comp_thresh_db",  .F32,  P + offset_of(dsp.Params, comp_thresh_db)},
	{"comp_ratio",      .F32,  P + offset_of(dsp.Params, comp_ratio)},
	{"comp_attack_ms",  .F32,  P + offset_of(dsp.Params, comp_attack_ms)},
	{"comp_release_ms", .F32,  P + offset_of(dsp.Params, comp_release_ms)},
	{"comp_makeup_db",  .F32,  P + offset_of(dsp.Params, comp_makeup_db)},
	{"output_gain_db",  .F32,  P + offset_of(dsp.Params, output_gain_db)},

	{"capture_device",  .Name, offset_of(Config, devices) + offset_of(Device_Choice, capture)},
	{"playback_device", .Name, offset_of(Config, devices) + offset_of(Device_Choice, playback)},

	{"hotkey_toggle_bypass_mods", .U16, HK + uintptr(Hotkey_Action.Toggle_Bypass) * size_of(Hotkey) + offset_of(Hotkey, mods)},
	{"hotkey_toggle_bypass_vk",   .U16, HK + uintptr(Hotkey_Action.Toggle_Bypass) * size_of(Hotkey) + offset_of(Hotkey, vk)},

	{"start_minimized", .Bool, offset_of(Config, start_minimized)},
	{"close_quits",     .Bool, offset_of(Config, close_quits)},
}

@(private, rodata)
EQ_KIND_NAMES := [dsp.EQ_Kind]string{
	.Off        = "off",
	.Peaking    = "peaking",
	.Low_Shelf  = "low_shelf",
	.High_Shelf = "high_shelf",
}

// ---------------------------------------------------------------------------
// Parse / format
// ---------------------------------------------------------------------------

// Applies every recognized `key = value` line in text onto c. Bad values are skipped.
config_parse :: proc(text: string, c: ^Config) {
	base := uintptr(c)
	rest := text
	for len(rest) > 0 {
		line: string
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line, rest = rest[:nl], rest[nl + 1:]
		} else {
			line, rest = rest, ""
		}
		line = strings.trim_space(line)
		if len(line) == 0 || line[0] == '#' || line[0] == ';' do continue
		eq := strings.index_byte(line, '=')
		if eq < 0 do continue
		k := strings.trim_space(line[:eq])
		v := strings.trim_space(line[eq + 1:])

		for &key in KEYS {
			if key.name != k do continue
			ptr := rawptr(base + key.offset)
			switch key.kind {
			case .Bool:
				if b, ok := strconv.parse_bool(v); ok do (^bool)(ptr)^ = b
			case .F32:
				if f, ok := strconv.parse_f32(v); ok do (^f32)(ptr)^ = f
			case .U16:
				if i, ok := strconv.parse_int(v); ok && i >= 0 && i <= 0xFFFF do (^u16)(ptr)^ = u16(i)
			case .EQ_Kind:
				for name, kind in EQ_KIND_NAMES do if name == v do (^dsp.EQ_Kind)(ptr)^ = kind
			case .Name:
				name_set((^Name)(ptr), v)
			}
			break
		}
	}
	config_sanitize(c)
}

// Writes the whole config into buf. Returns bytes written, or -1 if buf is too small.
config_format :: proc(c: ^Config, buf: []u8) -> int {
	base := uintptr(c)
	n := 0
	put :: proc(buf: []u8, n: ^int, s: string) -> bool {
		if n^ + len(s) > len(buf) do return false
		copy(buf[n^:], s)
		n^ += len(s)
		return true
	}
	num: [32]u8
	ok := put(buf, &n, "# voz settings\n")
	for &key in KEYS {
		ptr := rawptr(base + key.offset)
		v: string
		switch key.kind {
		case .Bool:    v = (^bool)(ptr)^ ? "true" : "false"
		case .F32:     v = strconv.write_float(num[:], f64((^f32)(ptr)^), 'g', -1, 32)
		case .U16:     v = strconv.write_uint(num[:], u64((^u16)(ptr)^), 10)
		case .EQ_Kind: v = EQ_KIND_NAMES[(^dsp.EQ_Kind)(ptr)^]
		case .Name:    v = name_string((^Name)(ptr))
		}
		ok &= put(buf, &n, key.name)
		ok &= put(buf, &n, " = ")
		ok &= put(buf, &n, v)
		ok &= put(buf, &n, "\n")
	}
	return ok ? n : -1
}

// Clamp to ranges the DSP is designed for, so a hand-edited file can't produce NaNs.
config_sanitize :: proc "contextless" (c: ^Config) {
	p := &c.params
	fix :: proc "contextless" (x: ^f32, lo, hi, def: f32) {
		if !(x^ == x^) do x^ = def // NaN
		x^ = clamp(x^, lo, hi)
	}
	nyq := f32(dsp.SAMPLE_RATE) * 0.45
	fix(&p.input_gain_db,   -24, 24, 0)
	fix(&p.ns_strength,       0, 1, 1)
	fix(&p.gate_voice_thresh, 0.05, 0.95, 0.5)
	fix(&p.highpass_hz,      20, 400, 80)
	fix(&p.gate_thresh_db,  -90, 0, -45)
	fix(&p.gate_floor_db,   -90, 0, -60)
	fix(&p.gate_attack_ms,    0, 100, 1)
	fix(&p.gate_hold_ms,      0, 1000, 80)
	fix(&p.gate_release_ms,   0, 2000, 120)
	for &b in p.eq {
		if u8(b.kind) > u8(max(dsp.EQ_Kind)) do b.kind = .Off
		fix(&b.freq_hz, 20, nyq, 1000)
		fix(&b.q,     0.1, 10, 1)
		fix(&b.gain_db, -24, 24, 0)
	}
	fix(&p.comp_thresh_db,  -60, 0, -20)
	fix(&p.comp_ratio,        1, 20, 3)
	fix(&p.comp_attack_ms,    0, 200, 5)
	fix(&p.comp_release_ms,   0, 2000, 120)
	fix(&p.comp_makeup_db,    0, 24, 4)
	fix(&p.output_gain_db,  -24, 24, 0)
}
