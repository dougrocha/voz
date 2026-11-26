package dsp

// RNNoise 0.2 (vendor/rnnoise, BSD-3). Build the static lib once: see vendor/rnnoise/README.md.
// rnnoise_process_frame: exactly RNNOISE_FRAME samples, int16-scaled floats, no allocation.
// Returns the voice activity probability for the frame.

RNNOISE_FRAME :: 480 // 10 ms @ 48 kHz

when ODIN_OS == .Windows {
	@(private) RNNOISE_LIB :: "../vendor/rnnoise/rnnoise.lib"
} else {
	@(private) RNNOISE_LIB :: "../vendor/rnnoise/librnnoise.a"
}
when !#exists(RNNOISE_LIB) {
	#panic("RNNoise isn't built: run vendor/rnnoise/build_rnnoise.bat (Windows) or build_rnnoise.sh")
}

foreign import rnnoise { RNNOISE_LIB }

Denoise_State :: struct {} // opaque

@(default_calling_convention = "c")
foreign rnnoise {
	rnnoise_create        :: proc(model: rawptr) -> ^Denoise_State ---
	rnnoise_destroy       :: proc(st: ^Denoise_State) ---
	rnnoise_init          :: proc(st: ^Denoise_State, model: rawptr) -> i32 ---
	rnnoise_get_frame_size :: proc() -> i32 ---
	rnnoise_process_frame :: proc(st: ^Denoise_State, out, input: [^]f32) -> f32 ---
}
