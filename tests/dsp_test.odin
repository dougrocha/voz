package tests

// Offline tests: `odin test tests`. Platform independent (dsp + shared only).

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

import "../dsp"
import "../shared"

FS :: f32(dsp.SAMPLE_RATE)

// Deterministic white noise in [-1, 1].
Lcg :: struct { s: u32 }
lcg_next :: proc(r: ^Lcg) -> f32 {
	r.s = r.s * 1664525 + 1013904223
	return f32(r.s >> 8) / f32(1 << 23) - 1
}

Signal :: enum { Sine, Noise, Silence }

// Runs `seconds` of signal through the chain in blocks whose sizes cycle through `sizes`.
// Returns false (and reports) on the first NaN/Inf or out-of-range sample.
run :: proc(t: ^testing.T, ch: ^dsp.Chain, sig: Signal, amp: f32, seconds: f32, sizes: []int) -> bool {
	buf: [dsp.MAX_BLOCK]f32
	rng := Lcg{1}
	phase: f32
	inc := 2 * math.PI * 1000 / FS
	total := int(seconds * FS)
	done, si := 0, 0
	for done < total {
		n := min(sizes[si % len(sizes)], total - done)
		si += 1
		block := buf[:n]
		for &s in block {
			switch sig {
			case .Sine:    s = amp * math.sin(phase); phase += inc; if phase > 2 * math.PI do phase -= 2 * math.PI
			case .Noise:   s = amp * lcg_next(&rng)
			case .Silence: s = 0
			}
		}
		dsp.chain_process(ch, block)
		for s, i in block {
			if math.is_nan(s) || math.is_inf(s) || abs(s) > 1 {
				testing.expectf(t, false, "bad sample %v at %d (+%d)", s, done, i)
				return false
			}
		}
		done += n
	}
	return true
}

SIZES := []int{1, 31, 32, 33, 480, dsp.MAX_BLOCK, 7, 256}

@(test)
chain_sine_and_noise_in_range :: proc(t: ^testing.T) {
	p := dsp.params_default()
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS)
	testing.expect(t, run(t, &ch, .Sine, 0.5, 2, SIZES))
	testing.expect(t, run(t, &ch, .Noise, 1, 2, SIZES))

	// Hot input: +24 dB into the chain must still clamp cleanly.
	p.input_gain_db = 24
	p.output_gain_db = 12
	dsp.chain_apply_params(&ch, &p, FS)
	testing.expect(t, run(t, &ch, .Noise, 1, 1, SIZES))
}

@(test)
chain_every_eq_kind_and_extremes :: proc(t: ^testing.T) {
	p := dsp.params_default()
	p.eq = {
		{.Peaking,    100,   0.3,  12},
		{.Low_Shelf,  200,   1.0, -12},
		{.High_Shelf, 10000, 0.5,  12},
		{.Peaking,    20000, 8.0, -12},
	}
	p.highpass_hz = 20
	p.comp_ratio = 1 // no-op compressor path
	p.gate_attack_ms, p.gate_release_ms, p.gate_hold_ms = 0, 0, 0
	p.comp_attack_ms, p.comp_release_ms = 0, 0
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS)
	testing.expect(t, run(t, &ch, .Noise, 1, 1, SIZES))
	testing.expect(t, ch.eq_count == 4)
}

@(test)
chain_silence_flushes_state :: proc(t: ^testing.T) {
	p := dsp.params_default()
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS)
	run(t, &ch, .Noise, 1, 0.5, SIZES)
	run(t, &ch, .Silence, 0, 5, SIZES)

	tiny :: proc(x: f32) -> bool { return x == 0 || abs(x) >= 1.17549435e-38 } // zero or normal
	testing.expect(t, tiny(ch.highpass.z1) && tiny(ch.highpass.z2), "highpass state denormal")
	for b in ch.eq do testing.expect(t, tiny(b.z1) && tiny(b.z2), "eq state denormal")
	testing.expect(t, tiny(ch.comp.env), "comp env denormal")
	testing.expect(t, ch.out_peak == 0, "silence in, silence out")
}

@(test)
chain_bypass_is_identity :: proc(t: ^testing.T) {
	p := dsp.params_default()
	p.bypass = true
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS)
	buf, ref: [480]f32
	rng := Lcg{7}
	for i in 0 ..< len(buf) { buf[i] = lcg_next(&rng); ref[i] = buf[i] }
	dsp.chain_process(&ch, buf[:])
	testing.expect(t, buf == ref)
}

@(test)
chain_gate_closes_on_quiet_input :: proc(t: ^testing.T) {
	p := dsp.params_default()
	p.highpass_on, p.comp_on = false, false
	for &b in p.eq do b.kind = .Off
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS)
	run(t, &ch, .Noise, 0.001, 1, SIZES) // -60 dBFS, below the -45 dB threshold
	testing.expectf(t, ch.gate.gain < 0.01, "gate gain %v", ch.gate.gain)
	run(t, &ch, .Sine, 0.5, 0.2, SIZES)
	testing.expectf(t, ch.gate.gain > 0.99, "gate gain %v", ch.gate.gain)
}

@(test)
chain_compressor_reduces_gain :: proc(t: ^testing.T) {
	p := dsp.params_default()
	p.highpass_on, p.gate_on = false, false
	for &b in p.eq do b.kind = .Off
	p.comp_thresh_db, p.comp_ratio, p.comp_makeup_db = -20, 4, 0
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS)
	run(t, &ch, .Sine, 1, 0.5, SIZES) // 0 dBFS peak: 20 dB over, expect ~15 dB GR
	testing.expectf(t, abs(ch.comp.gr_db - 15) < 1, "gr %v dB", ch.comp.gr_db)
}

@(test)
exchange_latest_wins :: proc(t: ^testing.T) {
	x: shared.Param_Exchange
	p := dsp.params_default()
	shared.exchange_init(&x, p)

	_, changed := shared.exchange_acquire(&x)
	testing.expect(t, !changed)

	p.input_gain_db = 1; shared.exchange_publish(&x, p)
	p.input_gain_db = 2; shared.exchange_publish(&x, p)
	got, c2 := shared.exchange_acquire(&x)
	testing.expect(t, c2 && got.input_gain_db == 2)
	_, c3 := shared.exchange_acquire(&x)
	testing.expect(t, !c3)

	// Interleave many times: indices must stay a permutation of {0,1,2}.
	for i in 0 ..< 100 {
		p.input_gain_db = f32(i); shared.exchange_publish(&x, p)
		g, c := shared.exchange_acquire(&x)
		testing.expect(t, c && g.input_gain_db == f32(i))
	}
}

@(test)
meters_peak_hold_and_reset :: proc(t: ^testing.T) {
	m: shared.Meters
	shared.meters_store(&m, {in_peak = 0.5, out_peak = 0.25, gate_gain = 1, comp_gr_db = 3})
	shared.meters_store(&m, {in_peak = 0.1, out_peak = 0.75, gate_gain = 0.5, comp_gr_db = 1})
	s := shared.meters_load(&m)
	testing.expect(t, s.in_peak == 0.5 && s.out_peak == 0.75)
	testing.expect(t, s.gate_gain == 0.5 && s.comp_gr_db == 1)
	s = shared.meters_load(&m)
	testing.expect(t, s.in_peak == 0 && s.out_peak == 0)
}

// Not a pass/fail budget (CI machines vary); logs cost relative to real time.
@(test)
chain_cost :: proc(t: ^testing.T) {
	st := dsp.rnnoise_create(nil)
	defer dsp.rnnoise_destroy(st)
	p := dsp.params_default() // includes noise suppression
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS, st)
	dsp.flush_denormals() // as the audio callback does
	noise, buf: [480]f32
	rng := Lcg{3}
	for &s in noise do s = 0.3 * lcg_next(&rng)
	BLOCKS :: 100 * 30 // 30 s of audio per case
	// Steady input, then silence: the tail is where RNNoise's state decays toward denormals.
	for silent in ([2]bool{false, true}) {
		start := time.tick_now()
		for _ in 0 ..< BLOCKS {
			buf = silent ? {} : noise
			dsp.chain_process(&ch, buf[:])
		}
		elapsed := time.duration_seconds(time.tick_since(start))
		log.infof("%s: 30 s of audio in %.2f ms -> %.4f%% of one core",
			silent ? "silence" : "noise  ", elapsed * 1000, elapsed / 30 * 100)
	}
}

// ---------------------------------------------------------------------------
// Noise suppression (RNNoise)
// ---------------------------------------------------------------------------

// Only the NS stage: everything else off.
ns_only :: proc() -> dsp.Params {
	p := dsp.params_default()
	p.highpass_on, p.gate_on, p.comp_on = false, false, false
	for &b in p.eq do b.kind = .Off
	p.ns_on = true
	return p
}

@(test)
ns_dry_path_is_delay_aligned :: proc(t: ^testing.T) {
	st := dsp.rnnoise_create(nil)
	defer dsp.rnnoise_destroy(st)
	p := ns_only()
	p.ns_strength = 0 // pure (delayed) dry: must be the input shifted by exactly NS_DELAY
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS, st)

	N :: dsp.RNNOISE_FRAME * 20
	input, output: [N]f32
	rng := Lcg{11}
	for &s in input do s = 0.5 * lcg_next(&rng)
	output = input
	for i := 0; i < N; i += dsp.RNNOISE_FRAME do dsp.chain_process(&ch, output[i:][:dsp.RNNOISE_FRAME])
	ok := true
	for i in dsp.NS_DELAY ..< N do if output[i] != input[i - dsp.NS_DELAY] { ok = false; break }
	testing.expect(t, ok, "dry path must equal input delayed by NS_DELAY")
}

@(test)
ns_suppresses_steady_noise :: proc(t: ^testing.T) {
	st := dsp.rnnoise_create(nil)
	defer dsp.rnnoise_destroy(st)
	p := ns_only()
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS, st)
	rng := Lcg{5}
	buf: [dsp.RNNOISE_FRAME]f32
	e_in, e_out: f64
	for f in 0 ..< 200 {
		for &s in buf do s = 0.1 * lcg_next(&rng)
		if f >= 50 do for s in buf do e_in += f64(s * s)
		dsp.chain_process(&ch, buf[:])
		if f >= 50 do for s in buf do e_out += f64(s * s)
	}
	db := 10 * math.log10(e_in / max(e_out, 1e-12))
	testing.expectf(t, db > 20, "only %.1f dB of noise reduction", db)
	testing.expect(t, ch.vad < 0.2, "noise isn't voice")
}

@(test)
voice_gate_rejects_loud_noise :: proc(t: ^testing.T) {
	st := dsp.rnnoise_create(nil)
	defer dsp.rnnoise_destroy(st)
	p := ns_only()
	p.ns_strength = 0                 // keep the noise in the signal: only the gate decides
	p.gate_on, p.gate_voice = true, true
	p.gate_thresh_db = -45            // the noise (~-20 dBFS) is far above the level threshold
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS, st)
	rng := Lcg{9}
	buf: [dsp.RNNOISE_FRAME]f32
	for _ in 0 ..< 100 {
		for &s in buf do s = 0.1 * lcg_next(&rng)
		dsp.chain_process(&ch, buf[:])
	}
	testing.expectf(t, ch.gate.gain < 0.01, "voice gate stayed open on noise (gain %v)", ch.gate.gain)

	// Same noise, level-only gate: stays open. That's the difference the voice gate makes.
	p.gate_voice = false
	dsp.chain_apply_params(&ch, &p, FS)
	for _ in 0 ..< 50 {
		for &s in buf do s = 0.1 * lcg_next(&rng)
		dsp.chain_process(&ch, buf[:])
	}
	testing.expectf(t, ch.gate.gain > 0.99, "level gate should be open (gain %v)", ch.gate.gain)
}

@(test)
ns_overload_suspends_until_reenabled :: proc(t: ^testing.T) {
	st := dsp.rnnoise_create(nil)
	defer dsp.rnnoise_destroy(st)
	p := ns_only()
	ch: dsp.Chain
	dsp.chain_init(&ch, &p, FS, st)
	testing.expect(t, ch.ns_run)

	dsp.chain_suspend_ns(&ch)
	p.input_gain_db = 3 // an unrelated edit must not resume it
	dsp.chain_apply_params(&ch, &p, FS)
	testing.expect(t, !ch.ns_run && dsp.chain_stats(&ch).ns_suspended)

	p.ns_on = false; dsp.chain_apply_params(&ch, &p, FS)
	p.ns_on = true;  dsp.chain_apply_params(&ch, &p, FS)
	testing.expect(t, ch.ns_run && !ch.ns_suspended, "toggling it back on resumes")
}

// The header a foreign frontend (voz-ui.exe) checks before using its mirrors.
@(test)
link_header :: proc(t: ^testing.T) {
	l: shared.Link
	shared.link_init(&l, dsp.params_default())
	testing.expect(t, l.magic == shared.LINK_MAGIC && l.version == shared.LINK_VERSION)
	testing.expect(t, l.meters_size == 7 * size_of(u32), "voz-ui mirrors 7 u32 meters")
	testing.expect(t, l.state.capture_sel == -1 && l.state.playback_sel == -1 && l.state.params == dsp.params_default())
}

// winui/CoreLink.cs mirrors these structs field for field. If this fails, update the C# mirror
// (and LINK_VERSION), then the numbers here.
@(test)
link_layout_contract :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(dsp.EQ_Band), 16)
	testing.expect_value(t, size_of(dsp.Params), 144)
	testing.expect_value(t, offset_of(dsp.Params, eq), 52)
	testing.expect_value(t, offset_of(dsp.Params, comp_on), 116)
	testing.expect_value(t, offset_of(dsp.Params, output_gain_db), 140)
	testing.expect_value(t, size_of(shared.Link_State), 17068)
	testing.expect_value(t, offset_of(shared.Link_State, status), 168)
	testing.expect_value(t, size_of(shared.Link), 17584)
	testing.expect_value(t, offset_of(shared.Link, core_hwnd), 32)
	testing.expect_value(t, offset_of(shared.Link, seq), 40)
	testing.expect_value(t, offset_of(shared.Link, state), 516)
}
