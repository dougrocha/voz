package shared

import "core:sync"
import "../dsp"

// ---------------------------------------------------------------------------
// Param_Exchange: lock-free triple buffer. One writer (UI), one reader (audio).
// Writer never blocks; reader always sees the latest complete snapshot.
// `state` packs the middle slot index (bits 0-1) and a dirty flag (bit 2).
// ---------------------------------------------------------------------------

@(private) DIRTY :: u32(1 << 2)
@(private) INDEX :: u32(3)

Param_Exchange :: struct {
	slots:     [3]dsp.Params,
	state:     u32, // atomic
	write_idx: u32, // UI thread only
	read_idx:  u32, // audio thread only
}

exchange_init :: proc(x: ^Param_Exchange, initial: dsp.Params) {
	x.slots     = {initial, initial, initial}
	x.write_idx = 0
	x.read_idx  = 2
	sync.atomic_store_explicit(&x.state, 1, .Release)
}

// UI thread.
exchange_publish :: proc(x: ^Param_Exchange, p: dsp.Params) {
	x.slots[x.write_idx] = p
	old := sync.atomic_exchange_explicit(&x.state, x.write_idx | DIRTY, .Acq_Rel)
	x.write_idx = old & INDEX
}

// Audio thread. One atomic load when nothing changed.
exchange_acquire :: proc "contextless" (x: ^Param_Exchange) -> (p: ^dsp.Params, changed: bool) {
	if sync.atomic_load_explicit(&x.state, .Acquire) & DIRTY == 0 {
		return &x.slots[x.read_idx], false
	}
	old := sync.atomic_exchange_explicit(&x.state, x.read_idx, .Acq_Rel)
	x.read_idx = old & INDEX
	return &x.slots[x.read_idx], true
}

// ---------------------------------------------------------------------------
// Meters: audio writes once per block, UI reads only while the window is visible.
// f32 stored as u32 bits; relaxed ordering, tearing between fields is harmless.
// ---------------------------------------------------------------------------

Meters :: struct {
	in_peak:    u32,
	out_peak:   u32,
	gate_gain:  u32,
	comp_gr_db: u32,
	vad:        u32, // f32 bits; < 0 when RNNoise isn't running
	ns_suspended: u32,
	xruns:      u32,
}

meters_store :: proc "contextless" (m: ^Meters, s: dsp.Chain_Stats) {
	// Peak-hold until the UI reads: keep the max since last load.
	store_max(&m.in_peak, s.in_peak)
	store_max(&m.out_peak, s.out_peak)
	sync.atomic_store_explicit(&m.gate_gain,  transmute(u32)s.gate_gain,  .Relaxed)
	sync.atomic_store_explicit(&m.comp_gr_db, transmute(u32)s.comp_gr_db, .Relaxed)
	sync.atomic_store_explicit(&m.vad, transmute(u32)s.vad, .Relaxed)
	sync.atomic_store_explicit(&m.ns_suspended, u32(s.ns_suspended), .Relaxed)
}

// Reads and resets peaks so the UI sees the max since its last frame.
meters_load :: proc(m: ^Meters) -> dsp.Chain_Stats {
	return {
		in_peak    = transmute(f32)sync.atomic_exchange_explicit(&m.in_peak,  0, .Relaxed),
		out_peak   = transmute(f32)sync.atomic_exchange_explicit(&m.out_peak, 0, .Relaxed),
		gate_gain  = transmute(f32)sync.atomic_load_explicit(&m.gate_gain,  .Relaxed),
		comp_gr_db = transmute(f32)sync.atomic_load_explicit(&m.comp_gr_db, .Relaxed),
		vad        = transmute(f32)sync.atomic_load_explicit(&m.vad, .Relaxed),
		ns_suspended = sync.atomic_load_explicit(&m.ns_suspended, .Relaxed) != 0,
	}
}

meters_add_xrun :: proc "contextless" (m: ^Meters) {
	sync.atomic_add_explicit(&m.xruns, 1, .Relaxed)
}

// Positive f32 bit patterns order the same as u32, so integer max works.
@(private)
store_max :: #force_inline proc "contextless" (dst: ^u32, v: f32) {
	bits := transmute(u32)max(v, 0)
	cur := sync.atomic_load_explicit(dst, .Relaxed)
	for bits > cur {
		prev, ok := sync.atomic_compare_exchange_weak_explicit(dst, cur, bits, .Relaxed, .Relaxed)
		if ok do break
		cur = prev
	}
}
