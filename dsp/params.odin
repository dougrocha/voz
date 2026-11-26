package dsp

EQ_Kind :: enum u8 {
	Off,
	Peaking,
	Low_Shelf,
	High_Shelf,
}

EQ_Band :: struct {
	kind:    EQ_Kind,
	freq_hz: f32,
	q:       f32, // Q for peaking, slope S for shelves
	gain_db: f32,
}

// User-facing values. Plain data, copied by value.
Params :: struct {
	bypass:          bool,
	input_gain_db:   f32,

	highpass_on:     bool,
	highpass_hz:     f32,

	ns_on:           bool,
	ns_strength:     f32, // 0..1 dry/wet

	gate_on:         bool,
	gate_voice:      bool, // gate also requires speech (RNNoise VAD)
	gate_voice_thresh: f32, // 0..1 voice probability
	gate_thresh_db:  f32,
	gate_floor_db:   f32,
	gate_attack_ms:  f32,
	gate_hold_ms:    f32,
	gate_release_ms: f32,

	eq:              [EQ_BANDS]EQ_Band,

	comp_on:         bool,
	comp_thresh_db:  f32,
	comp_ratio:      f32,
	comp_attack_ms:  f32,
	comp_release_ms: f32,
	comp_makeup_db:  f32,

	output_gain_db:  f32,
}

// Sensible starting point for a voice mic.
params_default :: proc "contextless" () -> Params {
	return Params{
		input_gain_db   = 0,

		highpass_on     = true,
		highpass_hz     = 80,

		ns_on           = true,
		ns_strength     = 1,

		gate_on         = true,
		gate_voice      = false,
		gate_voice_thresh = 0.5,
		gate_thresh_db  = -45,
		gate_floor_db   = -60,
		gate_attack_ms  = 1,
		gate_hold_ms    = 80,
		gate_release_ms = 120,

		eq = {
			{.Peaking,    250,  1.0, -2},  // mud
			{.Peaking,    3000, 1.0,  2},  // presence
			{.High_Shelf, 8000, 1.0,  1.5},// air
			{.Off,        1000, 1.0,  0},
		},

		comp_on         = true,
		comp_thresh_db  = -20,
		comp_ratio      = 3,
		comp_attack_ms  = 5,
		comp_release_ms = 120,
		comp_makeup_db  = 4,

		output_gain_db  = 0,
	}
}

// Recompute coefficients from Params without touching filter state (no clicks).
// Audio thread only, and only when params changed.
chain_apply_params :: proc "contextless" (ch: ^Chain, p: ^Params, fs: f32) {
	ch.bypass      = p.bypass
	ch.highpass_on = p.highpass_on
	ch.gate_on     = p.gate_on
	ch.comp_on     = p.comp_on

	// Re-enabling suppression (or the voice gate) is how the user clears an overload suspension.
	voice := p.gate_on && p.gate_voice
	if (p.ns_on && !ch.ns_on) || (voice && !ch.gate.voice_mode) do ch.ns_suspended = false
	run := ch.ns != nil && !ch.ns_suspended && (p.ns_on || voice)
	if run && !ch.ns_run {
		// Starting fresh: no stale audio from RNNoise's overlap buffers or the dry delay.
		rnnoise_init(ch.ns, nil)
		ch.ns_dry = {}
		ch.ns_pos = 0
		ch.gate.voice_open = false
	}
	ch.ns_on        = p.ns_on
	ch.ns_run       = run
	ch.ns_mix       = p.ns_on ? clamp(p.ns_strength, 0, 1) : 0
	ch.voice_thresh = p.gate_voice_thresh
	ch.gate.voice_mode = voice && run

	ch.input_gain  = db_to_lin(p.input_gain_db)
	ch.output_gain = db_to_lin(p.output_gain_db)

	ch.highpass.coefs = coefs_highpass(fs, p.highpass_hz, 0.7071)

	g := &ch.gate
	g.threshold = db_to_lin(p.gate_thresh_db)
	g.floor     = db_to_lin(p.gate_floor_db)
	g.att       = time_coef(p.gate_attack_ms, fs)
	g.rel       = time_coef(p.gate_release_ms, fs)
	g.hold      = i32(p.gate_hold_ms * 0.001 * fs)

	ch.eq_count = 0
	for band, i in p.eq {
		switch band.kind {
		case .Off:        continue
		case .Peaking:    ch.eq[i].coefs = coefs_peaking(fs, band.freq_hz, band.q, band.gain_db)
		case .Low_Shelf:  ch.eq[i].coefs = coefs_low_shelf(fs, band.freq_hz, band.q, band.gain_db)
		case .High_Shelf: ch.eq[i].coefs = coefs_high_shelf(fs, band.freq_hz, band.q, band.gain_db)
		}
		ch.eq_active[ch.eq_count] = u8(i)
		ch.eq_count += 1
	}

	c := &ch.comp
	c.threshold_db = p.comp_thresh_db
	c.slope        = 1 - 1 / max(p.comp_ratio, 1)
	c.makeup_db    = p.comp_makeup_db
	// Envelope runs per sample, so per-sample coefficients.
	c.att          = time_coef(p.comp_attack_ms, fs)
	c.rel          = time_coef(p.comp_release_ms, fs)
}

// First-time setup: coefficients + clean state. ns: the engine's RNNoise state, or nil.
chain_init :: proc "contextless" (ch: ^Chain, p: ^Params, fs: f32, ns: ^Denoise_State = nil) {
	ch^ = {}
	ch.ns = ns
	chain_apply_params(ch, p, fs)
	chain_reset_state(ch)
}
