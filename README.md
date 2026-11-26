# voz

Tiny Windows mic processor: mic → high-pass → noise suppression → noise gate → EQ → compressor → VB-Cable.
Apps (Discord, OBS, …) pick **CABLE Output** as their microphone.

Two parts that ship in one folder, with no installer:

- `voz.exe` (Odin): the audio engine. It lives in the tray, uses a few MB and does no work while idle.
- `voz-ui\voz-ui.exe` (WinUI 3, source in `winui/`): the voz window. It runs only while it's open and
  talks to `voz.exe` through shared memory.

## Use

1. Install [VB-Cable](https://vb-audio.com/Cable/) (run the x64 setup as admin, reboot).
2. Run `voz.exe` (from PowerShell: `.\voz.exe`). It opens the voz window; output auto-selects "CABLE Input".
3. In your apps, set the input device to **CABLE Output (VB-Audio Virtual Cable)**.

Click the tray icon to open it again. Settings live in `%APPDATA%\voz\voz.ini`. To start with
Windows, put a shortcut to `voz.exe` in `shell:startup`.

For now, closing the voz window quits voz (`close_quits = true`) and voz opens the window on start
(`start_minimized = false`). Set `close_quits = false` in `voz.ini` to keep voz running in the tray instead.

## Build

Needs Visual Studio Build Tools ("Desktop development with C++": `cl.exe`, `link.exe`, `rc.exe`, Windows SDK),
[Odin](https://github.com/odin-lang/Odin/releases) on `PATH`, and the .NET 10 SDK. From the repo:

```
vendor\rnnoise\build_rnnoise.bat      (once: builds the noise suppression library)
dotnet build winui -p:Platform=x64    (builds voz-ui\ next to voz.exe; again after C# changes)
odin run . -out:voz.exe -o:speed -subsystem:windows -resource:ui/resources.rc
```

`odin run` builds `voz.exe` and starts it, which opens the voz window. It deletes `voz.exe` when voz exits;
add `-keep-executable` to keep it, or use `odin build` with the same flags to build without running.

Noise suppression is [RNNoise](https://gitlab.xiph.org/xiph/rnnoise) 0.2 (BSD-3), built for AVX2 (Haswell / Zen
and newer). On older CPUs voz runs without it.

Offline DSP/config tests (any OS, after `sh vendor/rnnoise/build_rnnoise.sh`): `odin test tests`

The Odin-drawn panel in `ui/` is the future Linux UI (own rendering, veil later); it isn't built on Windows. To preview it off
Windows (renders to PNG with stb_truetype; build the stb libs once with `$ODIN_ROOT/vendor/stb/src/build_stb.sh`):

```
odin run tools/snapshot -o:speed -- <out_dir> <regular.ttf> <semibold.ttf> [scale]
```
