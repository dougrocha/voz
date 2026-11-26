@echo off
setlocal
rem Builds rnnoise.lib with MSVC. AVX2+FMA: voz checks the CPU at startup.
rem Works from any prompt: if cl isn't on PATH, finds Visual Studio via vswhere and loads vcvars64.
pushd "%~dp0" || exit /b 1

where cl >nul 2>nul && goto :build
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :novs
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR goto :novs
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul
where cl >nul 2>nul || goto :novs

:build
cl -nologo -MT -TC -O2 -fp:fast -arch:AVX2 -D__FMA__ -DHAVE_CONFIG_H -Iinclude -Isrc -c ^
  src\denoise.c src\rnn.c src\pitch.c src\kiss_fft.c src\celt_lpc.c src\nnet.c ^
  src\nnet_default.c src\parse_lpcnet_weights.c src\rnnoise_data.c src\rnnoise_tables.c
if errorlevel 1 goto :fail
lib -nologo -OUT:rnnoise.lib denoise.obj rnn.obj pitch.obj kiss_fft.obj celt_lpc.obj nnet.obj ^
  nnet_default.obj parse_lpcnet_weights.obj rnnoise_data.obj rnnoise_tables.obj
if errorlevel 1 goto :fail
del *.obj
echo Built vendor\rnnoise\rnnoise.lib
popd
exit /b 0

:novs
echo Could not find the MSVC compiler. Install Visual Studio Build Tools with the
echo "Desktop development with C++" workload, or run this from an x64 Native Tools prompt.
popd
exit /b 1

:fail
del *.obj 2>nul
popd
exit /b 1
