package config

import win "core:sys/windows"

// File IO through Win32 directly (core:os is in flux). Paths are UTF-16, NUL terminated.

PATH_MAX :: 512

Path :: [PATH_MAX]u16

@(private) KF_FLAG_DEFAULT :: 0

// %APPDATA%\voz\voz.ini. Creates the directory. Returns false if the path doesn't fit.
config_path :: proc(out: ^Path) -> bool {
	appdata: win.LPWSTR
	rfid := win.FOLDERID_RoamingAppData
	if win.SHGetKnownFolderPath(&rfid, KF_FLAG_DEFAULT, nil, &appdata) != 0 do return false
	defer win.CoTaskMemFree(appdata)

	n := 0
	put :: proc(out: ^Path, n: ^int, s: []u16) -> bool {
		if n^ + len(s) >= PATH_MAX do return false
		copy(out[n^:], s)
		n^ += len(s)
		return true
	}
	src := ([^]u16)(appdata)
	l := 0
	for src[l] != 0 do l += 1
	ok := put(out, &n, src[:l])
	ok &= put(out, &n, win.L("\\voz")[:4])
	if !ok do return false
	out[n] = 0
	win.CreateDirectoryW(win.wstring(&out[0]), nil) // fails harmlessly if it exists
	ok &= put(out, &n, win.L("\\voz.ini")[:8])
	out[n] = 0
	return ok
}

// Applies the file onto out (which should hold defaults). False if missing or unreadable.
config_load :: proc(path: ^Path, out: ^Config) -> bool {
	h := win.CreateFileW(win.wstring(&path[0]), win.GENERIC_READ, win.FILE_SHARE_READ, nil,
		win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE do return false
	defer win.CloseHandle(h)

	buf: [MAX_FILE]u8
	got: win.DWORD
	if !win.ReadFile(h, &buf[0], MAX_FILE, &got, nil) do return false
	config_parse(string(buf[:got]), out)
	return true
}

// Writes voz.ini.tmp then renames over voz.ini, so a crash never leaves a torn file.
config_save :: proc(path: ^Path, c: ^Config) -> bool {
	buf: [MAX_FILE]u8
	n := config_format(c, buf[:])
	if n < 0 do return false

	tmp: Path
	l := 0
	for path[l] != 0 do l += 1
	if l + 5 >= PATH_MAX do return false
	copy(tmp[:], path[:l])
	copy(tmp[l:], win.L(".tmp")[:4])
	tmp[l + 4] = 0

	h := win.CreateFileW(win.wstring(&tmp[0]), win.GENERIC_WRITE, 0, nil,
		win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE do return false
	wrote: win.DWORD
	ok := win.WriteFile(h, &buf[0], win.DWORD(n), &wrote, nil) && int(wrote) == n
	win.CloseHandle(h)
	if !ok do return false
	return bool(win.MoveFileExW(win.wstring(&tmp[0]), win.wstring(&path[0]), win.MOVEFILE_REPLACE_EXISTING))
}
