//go:build windows

package winsys

import (
	"errors"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

var (
	procCreateWindowExW     = user32.NewProc("CreateWindowExW")
	procShowWindow          = user32.NewProc("ShowWindow")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procSetFocus            = user32.NewProc("SetFocus")
	procGetMessageW         = user32.NewProc("GetMessageW")
	procTranslateMessage    = user32.NewProc("TranslateMessage")
	procDispatchMessageW    = user32.NewProc("DispatchMessageW")
	procPostMessageW        = user32.NewProc("PostMessageW")
	procPostThreadMessageW  = user32.NewProc("PostThreadMessageW")
	procDestroyWindow       = user32.NewProc("DestroyWindow")
	procIsWindow            = user32.NewProc("IsWindow")
	procGetCurrentThreadID  = kernel32.NewProc("GetCurrentThreadId")
)

const (
	wsOverlappedWindow = 0x00CF0000
	wsVScroll          = 0x00200000
	esMultiline        = 0x0004
	esAutoVScroll      = 0x0040
	esWantReturn       = 0x1000
	swShow             = 5
	wmClose            = 0x0010
	wmQuit             = 0x0012
)

// msg is MSG (48 bytes on 64-bit Windows).
type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	ptX     int32
	ptY     int32
}

var _ [48 - unsafe.Sizeof(msg{})]byte
var _ [unsafe.Sizeof(msg{}) - 48]byte

// TestField is the window the selftest types into: a top-level multi-line EDIT control (the system's own class, so no window
// procedure is needed) that takes the keyboard focus. Its text is read back with WM_GETTEXT, the same way the daemon reads the field
// it types into.
type TestField struct {
	hwnd uintptr
	tid  uint32
	done chan struct{}
}

// Open shows the window and starts its message loop on a thread of its own.
func (f *TestField) Open() error {
	f.done = make(chan struct{})
	ready := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		defer close(f.done)
		class, _ := syscall.UTF16PtrFromString("EDIT")
		title, _ := syscall.UTF16PtrFromString("") // the text of an EDIT window is its caption and its content: start empty
		hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(title)),
			wsOverlappedWindow|wsVScroll|esMultiline|esAutoVScroll|esWantReturn|wsVisible, 200, 200, 560, 220, 0, 0, 0, 0)
		if hwnd == 0 {
			ready <- errors.New("CreateWindowEx: " + err.Error())
			return
		}
		tid, _, _ := procGetCurrentThreadID.Call()
		f.hwnd, f.tid = hwnd, uint32(tid)
		procShowWindow.Call(hwnd, swShow)
		procSetForegroundWindow.Call(hwnd)
		procSetFocus.Call(hwnd)
		ready <- nil
		var m msg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 { // WM_QUIT, or an error
				break
			}
			procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
			procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
		}
		if alive, _, _ := procIsWindow.Call(hwnd); alive != 0 {
			procDestroyWindow.Call(hwnd)
		}
	}()
	return <-ready
}

// Focused: our window is in front and has the keyboard focus.
func (f *TestField) Focused() bool {
	return f.hwnd != 0 && foregroundWindow() == f.hwnd && focusedWindow() == f.hwnd
}

// Text is the field's text.
func (f *TestField) Text() (string, bool) {
	if f.hwnd == 0 {
		return "", false
	}
	return windowText(f.hwnd)
}

// Close closes the window and ends its message loop.
func (f *TestField) Close() {
	if f.hwnd == 0 {
		return
	}
	procPostMessageW.Call(f.hwnd, wmClose, 0, 0)
	procPostThreadMessageW.Call(uintptr(f.tid), wmQuit, 0, 0)
	select {
	case <-f.done:
	case <-time.After(2 * time.Second):
	}
}
