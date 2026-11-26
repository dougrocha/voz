#!/usr/bin/env sh
# Builds librnnoise.a (offline tests and tools off Windows). AVX2+FMA like the Windows build.
set -e
cd "$(dirname "$0")"
cc=${CC:-cc}
for f in denoise rnn pitch kiss_fft celt_lpc nnet nnet_default parse_lpcnet_weights rnnoise_data rnnoise_tables; do
	$cc -O2 -mavx2 -mfma -fPIC -w -DHAVE_CONFIG_H -Iinclude -Isrc -c src/$f.c -o $f.o
done
ar rcs librnnoise.a denoise.o rnn.o pitch.o kiss_fft.o celt_lpc.o nnet.o nnet_default.o parse_lpcnet_weights.o rnnoise_data.o rnnoise_tables.o
rm -f *.o
