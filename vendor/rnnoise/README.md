# RNNoise 0.2 (vendored)

Xiph.Org RNNoise v0.2 (BSD-3-Clause, see `COPYING`), unmodified sources from the official release
tarball plus a minimal `src/config.h`. Only the files needed for `rnnoise_process_frame` with the
built-in model are kept (no feature dumping, training, or x86 runtime dispatch). Built for AVX2+FMA
(Haswell / Zen and newer); voz checks the CPU at startup and disables noise suppression without it.

Build the static library once before `odin build`:

- Windows (any prompt; finds Visual Studio itself): `vendor\rnnoise\build_rnnoise.bat` → `rnnoise.lib`
- Linux/macOS (tests, snapshot): `sh vendor/rnnoise/build_rnnoise.sh` → `librnnoise.a`
