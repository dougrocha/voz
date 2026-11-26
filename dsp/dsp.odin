package dsp

import "core:math"
import x86 "core:simd/x86"

// Mono f32 block processing. No allocations. Each stage runs as its own tight loop over the
// block so coefficients stay in registers. Transcendentals (pow/log/exp) only run when params
// change or once per COMP_SUBBLOCK samples, never per sample.

SAMPLE_RATE   :: 48_000
MAX_BLOCK     :: 1024
EQ_BANDS      :: 4
COMP_SUBBLOCK :: 32
DENORMAL_EPS  :: f32(1e-15)

db_to_lin :: #force_inline proc "contextless" (db: f32) -> f32 { return math.pow(f32(10), db / 20) }
lin_to_db :: #force_inline proc "contextless" (x: f32) -> f32  { return 20 * math.log10(max(x, f32(1e-9))) }

// Flush-to-zero + denormals-are-zero for the calling thread (MXCSR). Our stages flush their own
// state per block, but RNNoise's C code doesn't: its filters and GRU decay into denormals after
// speech stops, roughly doubling its cost. Call at the top of every audio callback.
@(enable_target_feature = "sse")
flush_denormals :: proc "contextless" () {
	when ODIN_ARCH == .amd64 {
		MXCSR_FTZ :: 0x8000
		MXCSR_DAZ :: 0x0040
		x86._mm_setcsr(x86._mm_getcsr() | MXCSR_FTZ | MXCSR_DAZ)
	}
}

// One-pole smoothing coefficient for a time constant in ms at sample rate fs.
time_coef :: proc "contextless" (ms, fs: f32) -> f32 {
	if ms <= 0 do return 0
	return math.exp(-1 / (ms * 0.001 * fs))
}

// ---------------------------------------------------------------------------
// Biquad (RBJ cookbook), transposed direct form II
// ---------------------------------------------------------------------------

Biquad_Coefs :: struct {
	b0, b1, b2, a1, a2: f32,
}

Biquad :: struct {
	using coefs: Biquad_Coefs,
	z1, z2:      f32,
}

@(private)
normalize :: proc "contextless" (b0, b1, b2, a0, a1, a2: f32) -> Biquad_Coefs {
	inv := 1 / a0
	return {b0 * inv, b1 * inv, b2 * inv, a1 * inv, a2 * inv}
}

coefs_highpass :: proc "contextless" (fs, f0, q: f32) -> Biquad_Coefs {
	w0    := 2 * math.PI * f0 / fs
	cw    := math.cos(w0)
	alpha := math.sin(w0) / (2 * q)
	return normalize((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
}

coefs_peaking :: proc "contextless" (fs, f0, q, gain_db: f32) -> Biquad_Coefs {
	A     := math.pow(f32(10), gain_db / 40)
	w0    := 2 * math.PI * f0 / fs
	cw    := math.cos(w0)
	alpha := math.sin(w0) / (2 * q)
	return normalize(1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A)
}

// slope: shelf steepness S (1 = steepest without overshoot).
coefs_low_shelf :: proc "contextless" (fs, f0, slope, gain_db: f32) -> Biquad_Coefs {
	A     := math.pow(f32(10), gain_db / 40)
	w0    := 2 * math.PI * f0 / fs
	cw    := math.cos(w0)
	alpha := math.sin(w0) / 2 * math.sqrt((A + 1 / A) * (1 / slope - 1) + 2)
	sA    := 2 * math.sqrt(A) * alpha
	return normalize(
		A * ((A + 1) - (A - 1) * cw + sA),
		2 * A * ((A - 1) - (A + 1) * cw),
		A * ((A + 1) - (A - 1) * cw - sA),
		(A + 1) + (A - 1) * cw + sA,
		-2 * ((A - 1) + (A + 1) * cw),
		(A + 1) + (A - 1) * cw - sA,
	)
}

coefs_high_shelf :: proc "contextless" (fs, f0, slope, gain_db: f32) -> Biquad_Coefs {
	A     := math.pow(f32(10), gain_db / 40)
	w0    := 2 * math.PI * f0 / fs
	cw    := math.cos(w0)
	alpha := math.sin(w0) / 2 * math.sqrt((A + 1 / A) * (1 / slope - 1) + 2)
	sA    := 2 * math.sqrt(A) * alpha
	return normalize(
		A * ((A + 1) + (A - 1) * cw + sA),
		-2 * A * ((A - 1) + (A + 1) * cw),
		A * ((A + 1) + (A - 1) * cw - sA),
		(A + 1) - (A - 1) * cw + sA,
		2 * ((A - 1) - (A + 1) * cw),
		(A + 1) - (A - 1) * cw - sA,
	)
}

biquad_block :: proc "contextless" (f: ^Biquad, block: []f32) {
	b0, b1, b2, a1, a2 := f.b0, f.b1, f.b2, f.a1, f.a2
	z1, z2 := f.z1, f.z2
	for &s in block {
		x := s
		y := b0 * x + z1
		z1 = b1 * x - a1 * y + z2
		z2 = b2 * x - a2 * y
		s = y
	}
	// Flush denormals once per block instead of paying for them per sample.
	if abs(z1) < DENORMAL_EPS do z1 = 0
	if abs(z2) < DENORMAL_EPS do z2 = 0
	f.z1, f.z2 = z1, z2
}

// ---------------------------------------------------------------------------
// Noise gate: peak detector + hold + smoothed gain toward floor
// ---------------------------------------------------------------------------

Gate :: struct {
	threshold:  f32, // linear
	floor:      f32, // linear gain when closed
	att, rel:   f32, // smoothing coefs
	hold:       i32, // samples
	hold_left:  i32,
	gain:       f32,
	voice_mode: bool, // also require speech (RNNoise VAD), not just level
	voice_open: bool, // VAD verdict for the current frame (hysteresis applied)
}

gate_block :: proc "contextless" (g: ^Gate, block: []f32) {
	thr, floor, att, rel, hold := g.threshold, g.floor, g.att, g.rel, g.hold
	gain, hold_left := g.gain, g.hold_left
	// Voice mode with no speech: nothing can open the gate this block (raise thr past any sample).
	if g.voice_mode && !g.voice_open do thr = max(f32)
	for &s in block {
		target := floor
		if abs(s) > thr {
			hold_left = hold
			target = 1
		} else if hold_left > 0 {
			hold_left -= 1
			target = 1
		}
		c := target > gain ? att : rel
		gain = target + c * (gain - target)
		s *= gain
	}
	g.gain, g.hold_left = gain, hold_left
}

// ---------------------------------------------------------------------------
// Compressor: linear-domain peak envelope per sample; gain computed in dB once per
// COMP_SUBBLOCK samples and linearly interpolated across the sub-block.
// ---------------------------------------------------------------------------

Compressor :: struct {
	threshold_db: f32,
	slope:        f32, // 1 - 1/ratio
	makeup_db:    f32,
	att, rel:     f32,
	env:          f32, // linear peak envelope
	gain:         f32, // linear gain applied at end of last sub-block
	gr_db:        f32, // last computed gain reduction, for meters
}

compressor_block :: proc "contextless" (c: ^Compressor, block: []f32) {
	att, rel := c.att, c.rel
	env, gain := c.env, c.gain

	for start := 0; start < len(block); start += COMP_SUBBLOCK {
		sub := block[start:min(start + COMP_SUBBLOCK, len(block))]

		// Envelope over the sub-block.
		for s in sub {
			x := abs(s)
			k := x > env ? att : rel
			env = x + k * (env - x)
		}
		if env < DENORMAL_EPS do env = 0

		// One log + one pow per sub-block.
		over   := lin_to_db(env) - c.threshold_db
		gr     := over > 0 ? over * c.slope : 0
		target := db_to_lin(c.makeup_db - gr)
		c.gr_db = gr

		// Ramp gain from previous to target across the sub-block (no zipper noise).
		step := (target - gain) / f32(len(sub))
		for &s in sub {
			gain += step
			s *= gain
		}
		gain = target
	}

	c.env, c.gain = env, gain
}

// ---------------------------------------------------------------------------
// Noise suppression: RNNoise on whole 480-sample frames. Output lags input by NS_DELAY,
// so the dry path runs through the same delay and strength is a phase-aligned dry/wet mix.
// ---------------------------------------------------------------------------

NS_DELAY :: 2 * RNNOISE_FRAME // 20 ms: window overlap + one frame of lookahead (measured)

@(private)
ns_block :: proc "contextless" (ch: ^Chain, block: []f32) {
	// Fixed-size device callbacks deliver whole frames; anything else passes through.
	if len(block) % RNNOISE_FRAME != 0 do return
	mix := ch.ns_mix
	pos := ch.ns_pos
	for start := 0; start < len(block); start += RNNOISE_FRAME {
		frame := block[start:][:RNNOISE_FRAME]
		x, wet: [RNNOISE_FRAME]f32
		for v, i in frame do x[i] = v * 32768 // RNNoise works on int16-scaled floats
		vad := rnnoise_process_frame(ch.ns, &wet[0], &x[0])
		for &v, i in frame {
			dry := ch.ns_dry[pos]
			ch.ns_dry[pos] = v
			pos += 1
			if pos == NS_DELAY do pos = 0
			v = dry + (wet[i] * (1.0 / 32768) - dry) * mix
		}
		ch.vad = vad
		// Hysteresis so a word doesn't flutter the gate: open at thr, close below half of it.
		g := &ch.gate
		g.voice_open = vad >= ch.voice_thresh || (g.voice_open && vad >= ch.voice_thresh * 0.5)
	}
	ch.ns_pos = pos
}

// Audio thread: the overload guard tripped. Stays off until the user re-enables it.
chain_suspend_ns :: proc "contextless" (ch: ^Chain) {
	ch.ns_suspended = true
	ch.ns_run = false
	ch.gate.voice_mode = false // no VAD: fall back to the level gate
}

// ---------------------------------------------------------------------------
// Chain
// ---------------------------------------------------------------------------

Chain :: struct {
	bypass:      bool,
	highpass_on: bool,
	gate_on:     bool,
	comp_on:     bool,

	input_gain:  f32, // linear, precomputed
	output_gain: f32, // linear, precomputed

	highpass:    Biquad,
	gate:        Gate,
	eq:          [EQ_BANDS]Biquad,
	eq_active:   [EQ_BANDS]u8, // indices of enabled bands, packed
	eq_count:    int,
	comp:        Compressor,

	// Noise suppression. ns is owned by the engine (created once); nil = unavailable.
	ns:           ^Denoise_State,
	ns_on:        bool, // suppression wanted (Params)
	ns_run:       bool, // RNNoise runs: suppression or voice gate, and not suspended
	ns_suspended: bool, // overload guard tripped
	ns_mix:       f32,  // 0 = delayed dry only (VAD for the voice gate), 1 = fully suppressed
	ns_dry:       [NS_DELAY]f32,
	ns_pos:       int,
	vad:          f32,  // last frame's voice probability
	voice_thresh: f32,

	// Per-block detector values for meters.
	in_peak:     f32,
	out_peak:    f32,
}

Chain_Stats :: struct {
	in_peak, out_peak, gate_gain, comp_gr_db: f32,
	vad:          f32,  // < 0 when RNNoise isn't running
	ns_suspended: bool,
}

chain_reset_state :: proc "contextless" (ch: ^Chain) {
	ch.highpass.z1, ch.highpass.z2 = 0, 0
	for &b in ch.eq do b.z1, b.z2 = 0, 0
	ch.gate.hold_left = 0
	ch.gate.gain      = ch.gate.floor
	ch.comp.env       = 0
	ch.comp.gain      = db_to_lin(ch.comp.makeup_db)
	ch.in_peak, ch.out_peak = 0, 0
}

@(private)
block_peak :: #force_inline proc "contextless" (block: []f32) -> f32 {
	p: f32
	for s in block do p = max(p, abs(s))
	return p
}

// In place, mono. len(block) <= MAX_BLOCK.
chain_process :: proc "contextless" (ch: ^Chain, block: []f32) {
	if ch.bypass {
		ch.in_peak  = block_peak(block)
		ch.out_peak = ch.in_peak
		return
	}

	ig := ch.input_gain
	p: f32
	for &s in block {
		s *= ig
		p = max(p, abs(s))
	}
	ch.in_peak = p

	if ch.highpass_on do biquad_block(&ch.highpass, block)
	if ch.ns_run      do ns_block(ch, block)
	if ch.gate_on     do gate_block(&ch.gate, block)
	for i in 0 ..< ch.eq_count do biquad_block(&ch.eq[ch.eq_active[i]], block)
	if ch.comp_on     do compressor_block(&ch.comp, block)

	og := ch.output_gain
	p = 0
	for &s in block {
		s = clamp(s * og, -1, 1)
		p = max(p, abs(s))
	}
	ch.out_peak = p
}

chain_stats :: proc "contextless" (ch: ^Chain) -> Chain_Stats {
	return {
		in_peak    = ch.in_peak,
		out_peak   = ch.out_peak,
		gate_gain    = ch.gate_on ? ch.gate.gain : 1,
		comp_gr_db   = ch.comp_on ? ch.comp.gr_db : 0,
		vad          = ch.ns_run ? ch.vad : -1,
		ns_suspended = ch.ns_suspended,
	}
}
