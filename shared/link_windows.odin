package shared

import win "core:sys/windows"

// Creates the named, pagefile-backed Link. Returns nil if it can't (or if another core already
// made one); the caller then runs on a private Link and simply has no UI frontend.
// The mapping lives for the life of the process: no unmap, no close.
link_create :: proc() -> ^Link {
	h := win.CreateFileMappingW(win.INVALID_HANDLE_VALUE, nil, win.PAGE_READWRITE, 0, size_of(Link), LINK_NAME)
	if h == nil do return nil
	if win.GetLastError() == win.ERROR_ALREADY_EXISTS {
		win.CloseHandle(h)
		return nil
	}
	return (^Link)(win.MapViewOfFile(h, win.FILE_MAP_ALL_ACCESS, 0, 0, size_of(Link)))
}
