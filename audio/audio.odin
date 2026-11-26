package audio

import "base:intrinsics"
import "core:strings"
import "core:sys/info"
import "core:time"
import ma "vendor:miniaudio"

import "../dsp"
import "../shared"

// miniaudio duplex device: mic in, VB-Cable out, mono f32 @ 48 kHz.
// The data callback is the only code that runs on the audio thread.

MAX_DEVICES           :: 32
DEFAULT_PERIOD_FRAMES :: 480 // 10 ms

// Overload guard (like Krisp's): if a callback uses more than OVERLOAD_FRACTION of its period
// for OVERLOAD_BLOCKS callbacks in a row, noise suppression suspends itself until re-enabled.
OVERLOAD_FRACTION :: 0.7
OVERLOAD_BLOCKS   :: 8

Device_Info :: struct {
	id:         ma.device_id,
	name:       [256]u8, // fixed, no heap strings
	name_len:   u8,
	is_default: bool,
}

Device_List :: struct {
	capture:  [MAX_DEVICES]Device_Info, capture_count:  int,
	playback: [MAX_DEVICES]Device_Info, playback_count: int,
}

Engine_State :: enum u8 { Stopped, Running, Device_Lost }

Engine :: struct {
	ctx:       ma.context_type,
	device:    ma.device,
	state:     Engine_State, // atomic: written by UI and notification thread, read by UI
	has_ctx:   bool,         // UI thread only
	has_dev:   bool,         // UI thread only
	chain:     dsp.Chain,    // audio thread only (UI touches it only while stopped)
	ns:        ^dsp.Denoise_State, // RNNoise, created once; nil if the CPU lacks AVX2/FMA
	tsc_hz:    u64,          // cycle counter rate, 0 if unknown (guard disabled)
	cycle_budget: f64,       // cycles per frame allowed (OVERLOAD_FRACTION of real time)
	over_count: u32,         // audio thread only
	exchange:  ^shared.Param_Exchange,
	meters:    ^shared.Meters,
	ui_notify: proc "c" (), // posts a message to the UI thread on device loss; must be thread safe
}

engine_state :: proc "contextless" (e: ^Engine) -> Engine_State {
	return intrinsics.atomic_load_explicit(&e.state, .Acquire)
}

// UI thread. True only if we started the device and miniaudio still has it running.
// An unplugged explicit device can stop without any notification, so the UI checks this.
engine_running :: proc(e: ^Engine) -> bool {
	return e.has_dev && engine_state(e) == .Running && ma.device_get_state(&e.device) == .started
}

engine_init :: proc(e: ^Engine, x: ^shared.Param_Exchange, m: ^shared.Meters) -> bool {
	e.exchange, e.meters = x, m
	// RNNoise is built for AVX2+FMA; without them, noise suppression is unavailable.
	if f := info.cpu_features(); .avx2 in f && .fma in f do e.ns = dsp.rnnoise_create(nil)
	if hz, ok := time.tsc_frequency(50 * time.Millisecond); ok do e.tsc_hz = hz
	backends := [1]ma.backend{.wasapi}
	if ma.context_init(&backends[0], 1, nil, &e.ctx) != .SUCCESS do return false
	e.has_ctx = true
	return true
}

engine_shutdown :: proc(e: ^Engine) {
	engine_stop(e)
	if e.has_ctx do ma.context_uninit(&e.ctx)
	e.has_ctx = false
	if e.ns != nil do dsp.rnnoise_destroy(e.ns)
	e.ns = nil
}

// UI thread, on demand only. Copies names into the fixed list; no heap.
engine_enumerate :: proc(e: ^Engine, out: ^Device_List) -> bool {
	out.capture_count, out.playback_count = 0, 0
	return ma.context_enumerate_devices(&e.ctx, enum_callback, out) == .SUCCESS
}

// nil ids select the system defaults. period_frames is clamped to MAX_BLOCK.
engine_start :: proc(e: ^Engine, capture, playback: ^ma.device_id, period_frames: u32) -> bool {
	engine_stop(e)

	cfg := ma.device_config_init(.duplex)
	cfg.sampleRate                = dsp.SAMPLE_RATE
	cfg.periodSizeInFrames        = clamp(period_frames, 64, dsp.MAX_BLOCK)
	cfg.performanceProfile        = .low_latency
	cfg.noPreSilencedOutputBuffer = true
	cfg.noClip                    = true // the chain already clamps
	cfg.dataCallback              = data_callback
	cfg.notificationCallback      = notification_callback
	cfg.pUserData                 = e
	cfg.capture.pDeviceID         = capture
	cfg.capture.format            = .f32
	cfg.capture.channels          = 1
	cfg.capture.shareMode         = .shared
	cfg.playback.pDeviceID        = playback
	cfg.playback.format           = .f32
	cfg.playback.channels         = 1
	cfg.playback.shareMode        = .shared
	cfg.wasapi.usage              = .pro_audio // MMCSS "Pro Audio" on the callback thread
	// No auto rerouting: miniaudio would stop/restart the device from a COM thread behind our
	// back. The UI resolves "default" to an explicit device and reconciles on device changes.
	cfg.wasapi.noAutoStreamRouting = true

	if ma.device_init(&e.ctx, &cfg, &e.device) != .SUCCESS do return false
	e.has_dev = true

	// Device isn't running yet, so this thread may act as the exchange reader.
	// device_start publishes these writes to the audio thread.
	p, _ := shared.exchange_acquire(e.exchange)
	dsp.chain_init(&e.chain, p, dsp.SAMPLE_RATE, e.ns)
	e.cycle_budget = f64(e.tsc_hz) / dsp.SAMPLE_RATE * OVERLOAD_FRACTION
	e.over_count = 0

	intrinsics.atomic_store_explicit(&e.state, Engine_State.Running, .Release)
	if ma.device_start(&e.device) != .SUCCESS {
		engine_stop(e)
		return false
	}
	return true
}

engine_stop :: proc(e: ^Engine) {
	// Mark stopped first so the resulting `stopped` notification isn't read as device loss.
	intrinsics.atomic_store_explicit(&e.state, Engine_State.Stopped, .Release)
	if e.has_dev do ma.device_uninit(&e.device) // stops, then joins the audio thread
	e.has_dev = false
}

// ---------------------------------------------------------------------------
// miniaudio callbacks
// ---------------------------------------------------------------------------

@(private)
data_callback :: proc "c" (dev: ^ma.device, output, input: rawptr, frames: u32) {
	e := (^Engine)(dev.pUserData)
	t0 := intrinsics.read_cycle_counter()
	dsp.flush_denormals() // MXCSR is per thread; cheap enough to set every callback

	p, changed := shared.exchange_acquire(e.exchange)
	if changed do dsp.chain_apply_params(&e.chain, p, dsp.SAMPLE_RATE)

	out := ([^]f32)(output)[:frames]
	if input != nil {
		copy(out, ([^]f32)(input)[:frames])
	} else {
		for &s in out do s = 0
	}

	// Fixed-size callbacks are on, so this is one iteration in practice.
	for start := 0; start < len(out); start += dsp.MAX_BLOCK {
		dsp.chain_process(&e.chain, out[start:min(start + dsp.MAX_BLOCK, len(out))])
	}

	// Overload guard: only RNNoise is heavy enough to matter, so only it gets switched off.
	if e.chain.ns_run && e.cycle_budget != 0 {
		if f64(intrinsics.read_cycle_counter() - t0) > e.cycle_budget * f64(frames) {
			e.over_count += 1
			if e.over_count >= OVERLOAD_BLOCKS do dsp.chain_suspend_ns(&e.chain)
		} else {
			e.over_count = 0
		}
	}
	shared.meters_store(e.meters, dsp.chain_stats(&e.chain))
}

// Runs on a miniaudio thread. miniaudio has no "lost" notification: an unrequested
// `stopped` means the device went away (unplugged, disabled, format changed).
@(private)
notification_callback :: proc "c" (n: ^ma.device_notification) {
	if n.type != .stopped do return
	e := (^Engine)(n.pDevice.pUserData)
	_, lost := intrinsics.atomic_compare_exchange_strong_explicit(
		&e.state, Engine_State.Running, Engine_State.Device_Lost, .Acq_Rel, .Acquire)
	if lost && e.ui_notify != nil do e.ui_notify()
}

@(private)
enum_callback :: proc "c" (ctx: ^ma.context_type, kind: ma.device_type, info: ^ma.device_info, user: rawptr) -> b32 {
	out := (^Device_List)(user)
	d: ^Device_Info
	#partial switch kind {
	case .capture:
		if out.capture_count == MAX_DEVICES do return true
		d = &out.capture[out.capture_count]; out.capture_count += 1
	case .playback:
		if out.playback_count == MAX_DEVICES do return true
		d = &out.playback[out.playback_count]; out.playback_count += 1
	case:
		return true
	}
	d.id         = info.id
	d.is_default = bool(info.isDefault)
	n := 0
	for n < len(d.name) - 1 && info.name[n] != 0 {
		d.name[n] = u8(info.name[n])
		n += 1
	}
	d.name[n]  = 0
	d.name_len = u8(n)
	// Never offer a VB-Cable output as a mic: that's voz's own output, and recording it loops.
	if kind == .capture && is_cable_output(device_name(d)) do out.capture_count -= 1
	return true // keep enumerating
}

// VB-Cable endpoints: "CABLE Input (VB-Audio Virtual Cable)", "CABLE-A Output (VB-Audio Cable A)", ...
// Input is the playback side voz writes to; Output is the capture side apps record.
is_cable_input  :: proc "contextless" (name: string) -> bool { return is_cable(name, "Input") }
is_cable_output :: proc "contextless" (name: string) -> bool { return is_cable(name, "Output") }

@(private)
is_cable :: proc "contextless" (name, side: string) -> bool {
	return len(name) >= 5 && name[:5] == "CABLE" && strings.index(name[5:], side) >= 0
}

device_name :: proc "contextless" (d: ^Device_Info) -> string {
	return string(d.name[:d.name_len])
}

// Finds a device by exact UTF-8 name; nil when not found.
device_find :: proc "contextless" (devs: []Device_Info, name: string) -> ^Device_Info {
	if len(name) == 0 do return nil
	for &d in devs do if device_name(&d) == name do return &d
	return nil
}

device_default :: proc "contextless" (devs: []Device_Info) -> ^Device_Info {
	for &d in devs do if d.is_default do return &d
	return nil
}
