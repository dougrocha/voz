package shared

import "core:sync"
import "../dsp"

// ---------------------------------------------------------------------------
// Link: the block the core shares with an out-of-process UI frontend.
// The core keeps its Meters and Param_Exchange inside it, so the audio thread is unchanged.
// The header lets a foreign frontend (C#) check its mirrors before touching anything.
//
// Direction of data:
// - core → frontend: `state` (params, device lists, status), written only by the core's UI
//   thread under a sequence lock; the frontend copies it out and retries on a torn read.
// - frontend → core: WM_COPYDATA to `core_hwnd` with a Link_Cmd. The core's UI thread applies
//   it exactly as its own UI would (sanitize, publish, save, reconcile), so the exchange keeps
//   one writer and the core keeps sole ownership of the config file.
// ---------------------------------------------------------------------------

LINK_NAME        :: "Local\\voz.link"
LINK_MAGIC       :: u32(0x6B6E_6C76) // "vlnk" little-endian
LINK_VERSION     :: u32(3)
LINK_MAX_DEVICES :: 32
LINK_NAME_MAX    :: 256

Link_Cmd :: enum u32 {
	None,
	Set_Params,   // payload: dsp.Params
	Set_Capture,  // payload: Link_Name; empty = Windows default mic
	Set_Playback, // payload: Link_Name; empty = VB-Cable (auto)
	UI_Closed, // no payload; the core quits if close_quits is set
}

// Like config.Name, but with a u32 length so the C# mirror stays a plain blittable struct.
Link_Name :: struct {
	len:  u32,
	text: [LINK_NAME_MAX]u8, // UTF-8, not NUL terminated
}

Link_State :: struct {
	params:          dsp.Params,
	capture_count:   u32,
	playback_count:  u32,
	capture_sel:     i32, // index of the saved mic; -1 = default
	playback_sel:    i32, // index of the saved output; -1 = VB-Cable (auto)
	capture_default: i32, // index of the Windows default mic; -1 = none
	status_kind:     u32, // ui.Status_Kind: 0 ok, 1 warn, 2 error
	status:          Link_Name,
	capture:         [LINK_MAX_DEVICES]Link_Name,
	playback:        [LINK_MAX_DEVICES]Link_Name,
}

Link :: struct {
	magic:           u32,
	version:         u32,
	size:            u32,
	meters_offset:   u32,
	meters_size:     u32,
	params_size:     u32,
	state_offset:    u32,
	state_size:      u32,
	core_hwnd:       u64, // where commands go, and how a frontend tells the core is alive; 0 until it exists
	seq:             u32, // sequence lock over `state`: odd while the core writes it
	meters:          Meters,
	exchange:        Param_Exchange,
	state:           Link_State,
}

// Fills the header and the exchange. Call before the audio device starts.
link_init :: proc(l: ^Link, initial: dsp.Params) {
	l.meters = {}
	exchange_init(&l.exchange, initial)
	l.state = {}
	l.state.params = initial
	l.state.capture_sel, l.state.playback_sel, l.state.capture_default = -1, -1, -1
	l.size            = size_of(Link)
	l.meters_offset   = u32(offset_of(Link, meters))
	l.meters_size     = size_of(Meters)
	l.params_size     = size_of(dsp.Params)
	l.state_offset    = u32(offset_of(Link, state))
	l.state_size      = size_of(Link_State)
	l.version         = LINK_VERSION
	sync.atomic_store_explicit(&l.magic, LINK_MAGIC, .Release) // last: the header is complete
}

// Core UI thread only. Fill `state` between begin and end; a frontend that reads across the
// write sees the sequence change and retries.
link_write_begin :: proc(l: ^Link) -> ^Link_State {
	sync.atomic_store_explicit(&l.seq, l.seq + 1, .Relaxed)
	sync.atomic_thread_fence(.Release)
	return &l.state
}

link_write_end :: proc(l: ^Link) {
	sync.atomic_store_explicit(&l.seq, l.seq + 1, .Release)
}

link_name_set :: proc "contextless" (n: ^Link_Name, s: string) {
	n.len = u32(copy(n.text[:], s))
}

link_name_string :: proc "contextless" (n: ^Link_Name) -> string {
	return string(n.text[:min(n.len, LINK_NAME_MAX)])
}
