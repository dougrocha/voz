package main

import "core:mem"
_ :: mem // used only in debug builds
import win "core:sys/windows"

import "audio"
import "config"
import "shared"
import "ui"

// All long-lived state is global and fixed-size. Nothing is heap allocated after init.
// Meters and the param exchange live in the Link, shared with voz-ui.exe.
g_link_local: shared.Link // used only if the shared mapping can't be created
g_engine:   audio.Engine
g_app:      ui.App

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	CreateMutexW :: proc(attrs: rawptr, initial_owner: win.BOOL, name: win.wstring) -> win.HANDLE ---
}

main :: proc() {
	// One instance: a second launch just opens the first one's UI window.
	CreateMutexW(nil, false, "Local\\voz.single-instance")
	if win.GetLastError() == win.ERROR_ALREADY_EXISTS {
		if h := win.FindWindowW("voz", nil); h != nil do win.PostMessageW(h, ui.WM_APP_SHOW, 0, 0)
		return
	}

	g_app.cfg = config.config_default()
	have_cfg := config.config_path(&g_app.cfg_path) && config.config_load(&g_app.cfg_path, &g_app.cfg)

	link := shared.link_create()
	if link == nil do link = &g_link_local
	shared.link_init(link, g_app.cfg.params)
	g_app.link     = link
	g_app.engine   = &g_engine
	g_engine.ui_notify = notify_device_lost

	if !audio.engine_init(&g_engine, &link.exchange, &link.meters) {
		win.MessageBoxW(nil, "Couldn't initialize WASAPI.", "voz", win.MB_ICONERROR)
		return
	}

	// Debug builds enforce the zero-heap rule: any Odin allocation from here on panics.
	when ODIN_DEBUG {
		context.allocator      = mem.panic_allocator()
		context.temp_allocator = mem.panic_allocator()
	}

	// First run (no config file) opens the UI so there's something to find.
	if !ui.ui_init(&g_app, !have_cfg || !g_app.cfg.start_minimized) {
		win.MessageBoxW(nil, "Couldn't create the window.", "voz", win.MB_ICONERROR)
		return
	}
	code := ui.ui_run(&g_app)
	ui.ui_shutdown(&g_app) // stops audio, flushes a pending save
	audio.engine_shutdown(&g_engine)
	win.ExitProcess(u32(code))
}

// miniaudio notification thread → UI thread. hwnd is set before the device starts.
notify_device_lost :: proc "c" () {
	win.PostMessageW(g_app.hwnd, ui.WM_APP_DEVICE_LOST, 0, 0)
}
