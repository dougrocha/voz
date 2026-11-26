package tests

import "core:testing"
import "../audio"

// VB-Cable outputs are voz's own output; they must never show up as a mic.
@(test)
cable_output_filter :: proc(t: ^testing.T) {
	testing.expect(t, audio.is_cable_output("CABLE Output (VB-Audio Virtual Cable)"))
	testing.expect(t, audio.is_cable_output("CABLE-A Output (VB-Audio Cable A)"))
	testing.expect(t, !audio.is_cable_output("CABLE Input (VB-Audio Virtual Cable)"))
	testing.expect(t, !audio.is_cable_output("Microphone (Scarlett Solo USB)"))
	testing.expect(t, !audio.is_cable_output("CABLE"))
	testing.expect(t, !audio.is_cable_output(""))
}

@(test)
cable_input_match :: proc(t: ^testing.T) {
	testing.expect(t, audio.is_cable_input("CABLE Input (VB-Audio Virtual Cable)"))
	testing.expect(t, audio.is_cable_input("CABLE-B Input (VB-Audio Cable B)"))
	testing.expect(t, !audio.is_cable_input("CABLE Output (VB-Audio Virtual Cable)"))
	testing.expect(t, !audio.is_cable_input("Speakers (Realtek Audio)"))
}
