package ui

import "base:runtime"
import "core:unicode/utf16"
import win "core:sys/windows"

import "../audio"
import "../config"
import "../dsp"
import "../shared"

// Windows shell for the core: a tray icon and one hidden window that receives tray, device,
// hotkey and voz-ui messages. The UI is voz-ui.exe (WinUI), launched on
// demand; it lives next to voz.exe as voz-ui\voz-ui.exe. The UI thread blocks in
// GetMessageW. Timers: save debounce, device-change debounce, bounded device retry. In the
// tray: no wakeups.

WM_APP_TRAY        :: win.WM_APP + 1
WM_APP_DEVICE_LOST :: win.WM_APP + 2
WM_APP_SHOW        :: win.WM_APP + 3 // a second instance asks us to open the UI

@(private) TIMER_SAVE      :: 2
@(private) TIMER_RETRY     :: 3
@(private) TIMER_DEVCHANGE :: 4

@(private) SAVE_MS      :: 1000 // debounce after the last edit
@(private) DEVCHANGE_MS :: 500  // WM_DEVICECHANGE arrives in bursts
@(private) RETRY_MS     :: 2000 // device missing: try to reopen
@(private) RETRY_MAX    :: 30   // then wait for a device change or the UI opening

@(private) TRAY_ID :: 1
@(private) ICON_ID :: 1 // resources.rc

@(private) MENU_OPEN   :: 1
@(private) MENU_BYPASS :: 2
@(private) MENU_QUIT   :: 3

@(private) UI_REL :: `voz-ui\voz-ui.exe` // relative to voz.exe's folder

// Missing from core:sys/windows.
@(private) NOTIFYICON_VERSION_4 :: 4
@(private) NIF_SHOWTIP          :: 0x80
@(private) NIN_KEYSELECT        :: win.NIN_SELECT | 1
@(private) MOD_NOREPEAT         :: 0x4000
@(private) DBT_DEVNODES_CHANGED :: 0x0007
@(private) IDI_APPLICATION      :: 32512

App :: struct {
	hinst:     win.HINSTANCE,
	hwnd:      win.HWND, // hidden; never shown
	tray:      win.NOTIFYICONDATAW,
	taskbar_created: u32, // re-add the tray icon when Explorer restarts

	cfg:       config.Config,   // core-owned copy of params
	cfg_path:  config.Path,     // empty if %APPDATA% couldn't be resolved: never saves
	devices:   audio.Device_List,
	open_capture:   config.Name, // what the engine has open right now
	open_playback:  config.Name,
	engine:    ^audio.Engine,
	link:      ^shared.Link,     // shared with voz-ui.exe; never nil
	save_pending: bool,
	retries_left: int,           // bounded device retry; 0 = timer off
	status_buf:   [96]u8,
	status_len:   int,
	status_kind:  Status_Kind,

	ui_path:   [win.MAX_PATH]u16,     // voz-ui.exe, NUL-terminated; empty if voz.exe's path didn't fit
	ui_proc:   win.HANDLE,            // the voz-ui we launched; nil when none
	ctx:       runtime.Context,       // context for wnd_proc (main may install a panic allocator)
}

@(private) g_app: ^App // the one window; wnd_proc has no other way in

// Registers the class, creates the hidden window + tray icon, opens the audio devices.
// show: open the UI window once everything is up.
ui_init :: proc(app: ^App, show: bool) -> bool {
	g_app = app
	app.ctx = context
	app.hinst = win.HINSTANCE(win.GetModuleHandleW(nil))
	ui_path_init(app)

	class_name: win.wstring = "voz"
	wc := win.WNDCLASSEXW{
		cbSize        = size_of(win.WNDCLASSEXW),
		lpfnWndProc   = wnd_proc,
		hInstance     = app.hinst,
		hIconSm       = load_icon(app),
		lpszClassName = class_name,
	}
	if win.RegisterClassExW(&wc) == 0 do return false

	// A hidden top-level window (not message-only): those don't get WM_DEVICECHANGE broadcasts.
	app.hwnd = win.CreateWindowExW(0, class_name, "voz", win.WS_OVERLAPPED, 0, 0, 0, 0, nil, nil, app.hinst, nil)
	if app.hwnd == nil do return false
	app.link.core_hwnd = u64(uintptr(app.hwnd)) // voz-ui can send commands from here on

	app.taskbar_created = win.RegisterWindowMessageW("TaskbarCreated")
	tray_add(app, wc.hIconSm)
	hotkeys_register(app)

	if !reconcile(app) do retry_arm(app)

	if show do ui_open(app)
	return true
}

// GetMessageW loop; returns the exit code.
ui_run :: proc(app: ^App) -> int {
	msg: win.MSG
	for {
		r := win.GetMessageW(&msg, nil, 0, 0)
		if r == 0 do return int(msg.wParam)
		if r < 0 do return 1
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

// Stops audio and flushes a pending save. The tray icon goes in WM_DESTROY.
ui_shutdown :: proc(app: ^App) {
	audio.engine_stop(app.engine)
	save_now(app)
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

@(private)
wnd_proc :: proc "system" (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	app := g_app
	if app == nil || app.hwnd == nil do return win.DefWindowProcW(hwnd, msg, wp, lp)
	context = app.ctx

	switch msg {
	case win.WM_TIMER:
		switch wp {
		case TIMER_SAVE:
			win.KillTimer(hwnd, TIMER_SAVE)
			save_now(app)
		case TIMER_DEVCHANGE:
			win.KillTimer(hwnd, TIMER_DEVCHANGE)
			if !reconcile(app) do retry_arm(app)
		case TIMER_RETRY:
			app.retries_left -= 1
			if reconcile(app) do app.retries_left = 0
			if app.retries_left <= 0 do win.KillTimer(hwnd, TIMER_RETRY)
		}
		return 0

	case WM_APP_TRAY:
		switch u32(win.LOWORD(lp)) {
		case win.NIN_SELECT, NIN_KEYSELECT: ui_open(app)
		case win.WM_CONTEXTMENU:            tray_menu(app, i32(i16(win.LOWORD(wp))), i32(i16(win.HIWORD(wp))))
		}
		return 0

	case WM_APP_DEVICE_LOST:
		if audio.engine_state(app.engine) == .Device_Lost {
			audio.engine_stop(app.engine)
			if !reconcile(app) do retry_arm(app)
		}
		return 0

	case win.WM_DEVICECHANGE:
		// Hardware added/removed, or the default device changed. Event driven: free while idle.
		if wp == DBT_DEVNODES_CHANGED do win.SetTimer(hwnd, TIMER_DEVCHANGE, DEVCHANGE_MS, nil)
		return 1

	case WM_APP_SHOW:
		ui_open(app)
		return 0

	case win.WM_COPYDATA: // a command from voz-ui.exe
		cds := (^win.COPYDATASTRUCT)(uintptr(lp))
		return link_command(app, shared.Link_Cmd(cds.dwData), ([^]u8)(cds.lpData)[:cds.cbData]) ? 1 : 0

	case win.WM_HOTKEY:
		action := int(wp) - 1
		if action >= 0 && action < len(config.Hotkey_Action) do hotkey_action(app, config.Hotkey_Action(action))
		return 0

	case win.WM_ENDSESSION:
		if wp != 0 do save_now(app) // logoff/shutdown inside the save debounce
		return 0

	case win.WM_DESTROY:
		win.Shell_NotifyIconW(win.NIM_DELETE, &app.tray) // while the hwnd still identifies it
		ui_close(app) // its window would only say "voz isn't running"
		win.PostQuitMessage(0)
		return 0

	case:
		if msg == app.taskbar_created && msg != 0 {
			win.Shell_NotifyIconW(win.NIM_ADD, &app.tray)
			win.Shell_NotifyIconW(win.NIM_SETVERSION, &app.tray)
			return 0
		}
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}

// ---------------------------------------------------------------------------
// voz-ui.exe
// ---------------------------------------------------------------------------

@(private)
ui_path_init :: proc(app: ^App) {
	p := app.ui_path[:]
	n := int(win.GetModuleFileNameW(nil, &p[0], u32(len(p))))
	if n == 0 || n >= len(p) { p[0] = 0; return }
	for n > 0 && p[n - 1] != '\\' do n -= 1 // keep the trailing backslash
	if n + len(UI_REL) >= len(p) { p[0] = 0; return }
	p[n + utf16.encode_string(p[n:len(p) - 1], UI_REL)] = 0
}

// Launches voz-ui, or brings its window forward if it's already running.
@(private)
ui_open :: proc(app: ^App) {
	// The UI window opening is when an unnoticed dead device gets picked up.
	if !audio.engine_running(app.engine) && !reconcile(app) do retry_arm(app)

	if hwnd := ui_window(app); hwnd != nil {
		win.ShowWindow(hwnd, win.SW_RESTORE)
		win.SetForegroundWindow(hwnd) // allowed: we're handling the user's click
		return
	}
	if app.ui_proc != nil {
		if win.WaitForSingleObject(app.ui_proc, 0) == win.WAIT_TIMEOUT do return // running, no window yet
		win.CloseHandle(app.ui_proc)
		app.ui_proc = nil
	}
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	path := win.wstring(&app.ui_path[0])
	if app.ui_path[0] == 0 || !win.CreateProcessW(path, nil, nil, nil, false, 0, nil, nil, &si, &pi) {
		win.MessageBoxW(nil, "Couldn't start voz-ui.exe. It should be in the voz-ui folder next to voz.exe.",
			"voz", win.MB_ICONERROR)
		return
	}
	win.CloseHandle(pi.hThread)
	app.ui_proc = pi.hProcess
}

// Closes the voz-ui we launched, if its window is up.
@(private)
ui_close :: proc(app: ^App) {
	if hwnd := ui_window(app); hwnd != nil do win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
}

// The visible top-level window of the voz-ui we launched; nil if none.
@(private)
ui_window :: proc(app: ^App) -> win.HWND {
	if app.ui_proc == nil || win.WaitForSingleObject(app.ui_proc, 0) != win.WAIT_TIMEOUT do return nil
	Find :: struct { pid: u32, hwnd: win.HWND }
	f := Find{pid = win.GetProcessId(app.ui_proc)}
	win.EnumWindows(proc "system" (hwnd: win.HWND, lp: win.LPARAM) -> win.BOOL {
		f := (^Find)(uintptr(lp))
		pid: u32
		win.GetWindowThreadProcessId(hwnd, &pid)
		if pid != f.pid || !win.IsWindowVisible(hwnd) do return true
		f.hwnd = hwnd
		return false // found: stop
	}, win.LPARAM(uintptr(&f)))
	return f.hwnd
}

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

// Saved mic if connected, else the Windows default, else the first mic (a mic fallback is
// harmless). The list never holds a VB-Cable output, so when Windows' default mic is one, this
// picks a real mic instead of letting the system default loop voz's output back in.
@(private)
capture_target :: proc(app: ^App) -> ^audio.Device_Info {
	d := &app.devices
	devs := d.capture[:d.capture_count]
	if dev := audio.device_find(devs, config.name_string(&app.cfg.devices.capture)); dev != nil do return dev
	if dev := audio.device_default(devs); dev != nil do return dev
	return len(devs) > 0 ? &devs[0] : nil
}

// Saved output, or the first VB-Cable input when none is saved. Never the default output:
// that's usually speakers, and mic → speakers howls.
@(private)
playback_target :: proc(app: ^App) -> ^audio.Device_Info {
	d := &app.devices
	devs := d.playback[:d.playback_count]
	if name := config.name_string(&app.cfg.devices.playback); len(name) > 0 do return audio.device_find(devs, name)
	for &dev in devs do if audio.is_cable_input(audio.device_name(&dev)) do return &dev
	return nil
}

// Make the open devices match the wanted ones. Restarts only on a mismatch or a dead device,
// so it's cheap to call from every trigger (startup, device change, loss, the UI opening).
@(private)
reconcile :: proc(app: ^App) -> bool {
	defer link_sync(app) // device lists and status may have changed
	audio.engine_enumerate(app.engine, &app.devices)
	play := playback_target(app)
	if play == nil {
		audio.engine_stop(app.engine)
		app.open_capture.len, app.open_playback.len = 0, 0
		saved := config.name_string(&app.cfg.devices.playback)
		status(app, saved == "" ? "VB-Cable not found. Install it, or pick an output." : "Output device not connected.", .Error)
		return false
	}
	cap := capture_target(app)
	if cap == nil {
		audio.engine_stop(app.engine)
		app.open_capture.len, app.open_playback.len = 0, 0
		status(app, "No microphone found.", .Error)
		return false
	}
	cap_name := audio.device_name(cap)
	if audio.engine_running(app.engine) &&
	   config.name_string(&app.open_playback) == audio.device_name(play) &&
	   config.name_string(&app.open_capture) == cap_name {
		return true
	}

	ok := audio.engine_start(app.engine, &cap.id, &play.id, audio.DEFAULT_PERIOD_FRAMES)
	if ok {
		config.name_set(&app.open_capture, cap_name)
		config.name_set(&app.open_playback, audio.device_name(play))
		status(app, "Running  ·  48 kHz  ·  10 ms", .Ok)
	} else {
		app.open_capture.len, app.open_playback.len = 0, 0
		status(app, "Couldn't open the audio devices.", .Error)
	}
	return ok
}

// ---------------------------------------------------------------------------
// Link: the state voz-ui.exe shows, and the commands it sends back
// ---------------------------------------------------------------------------

// Copies params, device lists and status into the shared block. Called after anything that
// changes them; cheap enough not to bother tracking which part changed.
@(private)
link_sync :: proc(app: ^App) {
	s := shared.link_write_begin(app.link)
	defer shared.link_write_end(app.link)
	s.params = app.cfg.params
	d := &app.devices
	s.capture_count  = u32(min(d.capture_count, shared.LINK_MAX_DEVICES))
	s.playback_count = u32(min(d.playback_count, shared.LINK_MAX_DEVICES))
	s.capture_sel, s.playback_sel, s.capture_default = -1, -1, -1
	saved_cap  := config.name_string(&app.cfg.devices.capture)
	saved_play := config.name_string(&app.cfg.devices.playback)
	for &dev, i in d.capture[:s.capture_count] {
		name := audio.device_name(&dev)
		shared.link_name_set(&s.capture[i], name)
		if len(saved_cap) > 0 && name == saved_cap do s.capture_sel = i32(i)
		if dev.is_default do s.capture_default = i32(i)
	}
	for &dev, i in d.playback[:s.playback_count] {
		name := audio.device_name(&dev)
		shared.link_name_set(&s.playback[i], name)
		if len(saved_play) > 0 && name == saved_play do s.playback_sel = i32(i)
	}
	s.status_kind = u32(app.status_kind)
	shared.link_name_set(&s.status, string(app.status_buf[:app.status_len]))
}

// Applies a command from voz-ui. Payloads come from another process: sizes are checked
// and params are sanitized like a hand-edited config file.
@(private)
link_command :: proc(app: ^App, cmd: shared.Link_Cmd, payload: []u8) -> bool {
	switch cmd {
	case .Set_Params:
		if len(payload) != size_of(dsp.Params) do return false
		c := app.cfg
		c.params = (^dsp.Params)(raw_data(payload))^
		config.config_sanitize(&c)
		params_changed(app, c.params)
	case .Set_Capture, .Set_Playback:
		if len(payload) != size_of(shared.Link_Name) do return false
		name := shared.link_name_string((^shared.Link_Name)(raw_data(payload)))
		config.name_set(cmd == .Set_Capture ? &app.cfg.devices.capture : &app.cfg.devices.playback, name)
		if !reconcile(app) do retry_arm(app) // syncs the link
		arm_save(app)
	case .UI_Closed:
		if app.cfg.close_quits do win.DestroyWindow(app.hwnd) // closing the UI quits voz
	case .None:
		return false
	}
	return true
}

// Applies new params: the audio thread, the tray tooltip, the config file and voz-ui.
@(private)
params_changed :: proc(app: ^App, p: dsp.Params) {
	bypass_changed := p.bypass != app.cfg.params.bypass
	app.cfg.params = p
	shared.exchange_publish(&app.link.exchange, app.cfg.params)
	if bypass_changed do tray_tip(app) // the tooltip only shows bypass; skip the Explorer call otherwise
	arm_save(app)
	link_sync(app)
}

// Bounded retry: RETRY_MAX ticks, then idle until a device change or the UI opening.
@(private)
retry_arm :: proc(app: ^App) {
	app.retries_left = RETRY_MAX
	win.SetTimer(app.hwnd, TIMER_RETRY, RETRY_MS, nil)
}

@(private)
status :: proc(app: ^App, s: string, kind: Status_Kind) {
	app.status_len = copy(app.status_buf[:], s)
	app.status_kind = kind
}

@(private)
arm_save :: proc(app: ^App) {
	app.save_pending = true
	win.SetTimer(app.hwnd, TIMER_SAVE, SAVE_MS, nil) // re-arming resets the countdown
}

@(private)
save_now :: proc(app: ^App) {
	if app.save_pending && app.cfg_path[0] != 0 do config.config_save(&app.cfg_path, &app.cfg)
	app.save_pending = false
}

// ---------------------------------------------------------------------------
// Tray
// ---------------------------------------------------------------------------

@(private)
load_icon :: proc(app: ^App) -> win.HICON {
	sz := win.GetSystemMetricsForDpi(win.SM_CXSMICON, win.GetDpiForSystem())
	icon := win.HICON(win.LoadImageW(app.hinst, cast(win.wstring)win.MAKEINTRESOURCEW(ICON_ID), win.IMAGE_ICON, sz, sz, 0))
	if icon == nil do icon = win.LoadIconW(nil, cast(win.wstring)win.MAKEINTRESOURCEW(IDI_APPLICATION))
	return icon
}

@(private)
tray_add :: proc(app: ^App, icon: win.HICON) {
	t := &app.tray
	t.cbSize           = size_of(win.NOTIFYICONDATAW)
	t.hWnd             = app.hwnd
	t.uID              = TRAY_ID
	t.uFlags           = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP | NIF_SHOWTIP
	t.uCallbackMessage = WM_APP_TRAY
	t.hIcon            = icon
	t.uVersion         = NOTIFYICON_VERSION_4
	tray_tip(app)
	win.Shell_NotifyIconW(win.NIM_ADD, t)
	win.Shell_NotifyIconW(win.NIM_SETVERSION, t)
}

@(private)
tray_tip :: proc(app: ^App) {
	tip := app.cfg.params.bypass ? "voz (bypassed)" : "voz"
	n := utf16.encode_string(app.tray.szTip[:len(app.tray.szTip) - 1], tip)
	app.tray.szTip[n] = 0
	if app.tray.cbSize != 0 do win.Shell_NotifyIconW(win.NIM_MODIFY, &app.tray)
}

@(private)
tray_menu :: proc(app: ^App, x, y: i32) {
	m := win.CreatePopupMenu()
	defer win.DestroyMenu(m)
	win.AppendMenuW(m, win.MF_STRING, MENU_OPEN, "Open voz")
	win.AppendMenuW(m, win.MF_STRING | (app.cfg.params.bypass ? win.MF_CHECKED : 0), MENU_BYPASS, "Bypass")
	win.AppendMenuW(m, win.MF_SEPARATOR, 0, nil)
	win.AppendMenuW(m, win.MF_STRING, MENU_QUIT, "Quit")

	win.SetForegroundWindow(app.hwnd) // otherwise the menu won't close on outside click
	cmd := win.TrackPopupMenu(m, win.TPM_RIGHTBUTTON | win.TPM_RETURNCMD | win.TPM_NONOTIFY | win.TPM_BOTTOMALIGN, x, y, 0, app.hwnd, nil)
	win.PostMessageW(app.hwnd, win.WM_NULL, 0, 0)

	switch cmd {
	case MENU_OPEN:   ui_open(app)
	case MENU_BYPASS: set_bypass(app, !app.cfg.params.bypass)
	case MENU_QUIT:   win.DestroyWindow(app.hwnd)
	}
}

@(private)
set_bypass :: proc(app: ^App, on: bool) {
	p := app.cfg.params
	p.bypass = on
	params_changed(app, p)
}

// ---------------------------------------------------------------------------
// Hotkeys: plumbing only. Bindings come from config; none are set by default.
// ---------------------------------------------------------------------------

@(private)
hotkeys_register :: proc(app: ^App) {
	for hk, action in app.cfg.hotkeys {
		if hk.vk == 0 do continue
		win.RegisterHotKey(app.hwnd, i32(action) + 1, u32(hk.mods) | MOD_NOREPEAT, u32(hk.vk))
	}
}

@(private)
hotkey_action :: proc(app: ^App, action: config.Hotkey_Action) {
	switch action {
	case .Toggle_Bypass: set_bypass(app, !app.cfg.params.bypass)
	}
}
