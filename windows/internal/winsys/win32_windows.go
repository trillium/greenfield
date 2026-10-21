//go:build windows

package winsys

import (
	"errors"
	"fmt"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"

	"greenfield-inserter/internal/inserter"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	advapi32 = syscall.NewLazyDLL("advapi32.dll")

	procSendInput             = user32.NewProc("SendInput")
	procGetForegroundWindow   = user32.NewProc("GetForegroundWindow")
	procGetGUIThreadInfo      = user32.NewProc("GetGUIThreadInfo")
	procGetClassNameW         = user32.NewProc("GetClassNameW")
	procSendMessageTimeoutW   = user32.NewProc("SendMessageTimeoutW")
	procGetWindowLongPtrW     = user32.NewProc("GetWindowLongPtrW")
	procOpenInputDesktop      = user32.NewProc("OpenInputDesktop")
	procCloseDesktop          = user32.NewProc("CloseDesktop")
	procGetWindowThreadProcID = user32.NewProc("GetWindowThreadProcessId")

	procOpenProcess         = kernel32.NewProc("OpenProcess")
	procCloseHandle         = kernel32.NewProc("CloseHandle")
	procGetCurrentProcess   = kernel32.NewProc("GetCurrentProcess")
	procOpenProcessToken    = advapi32.NewProc("OpenProcessToken")
	procGetTokenInformation = advapi32.NewProc("GetTokenInformation")
)

const (
	wmGetText       = 0x000D
	wmGetTextLength = 0x000E
	smtoAbortIfHung = 0x0002
	gwlStyle        = ^uintptr(15) // -16

	desktopSwitchDesktop = 0x0100

	processQueryLimitedInformation = 0x1000
	tokenQuery                     = 0x0008
	tokenElevation                 = 20 // TOKEN_INFORMATION_CLASS TokenElevation

	errorAccessDenied = 5
)

// guiThreadInfo is GUITHREADINFO.
type guiThreadInfo struct {
	cbSize        uint32
	flags         uint32
	hwndActive    uintptr
	hwndFocus     uintptr
	hwndCapture   uintptr
	hwndMenuOwner uintptr
	hwndMoveSize  uintptr
	hwndCaret     uintptr
	rcCaret       [4]int32
}

func foregroundWindow() uintptr {
	h, _, _ := procGetForegroundWindow.Call()
	return h
}

// focusedWindow is the control with the keyboard focus in the foreground window's thread (0 when there is none).
func focusedWindow() uintptr {
	fg := foregroundWindow()
	if fg == 0 {
		return 0
	}
	tid, _, _ := procGetWindowThreadProcID.Call(fg, 0)
	var info guiThreadInfo
	info.cbSize = uint32(unsafe.Sizeof(info))
	if ok, _, _ := procGetGUIThreadInfo.Call(tid, uintptr(unsafe.Pointer(&info))); ok == 0 {
		return 0
	}
	return info.hwndFocus
}

func className(hwnd uintptr) string {
	var buf [256]uint16
	n, _, _ := procGetClassNameW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:n])
}

// windowText reads a control's text with WM_GETTEXT, giving up after 200 ms so a hung app cannot hold a request. ok is false when
// the control does not answer.
func windowText(hwnd uintptr) (string, bool) {
	var length uintptr
	if r, _, _ := procSendMessageTimeoutW.Call(hwnd, wmGetTextLength, 0, 0, smtoAbortIfHung, 200, uintptr(unsafe.Pointer(&length))); r == 0 {
		return "", false
	}
	if length == 0 {
		return "", true
	}
	if length > 4<<20 { // do not copy a huge document for every request
		return "", false
	}
	buf := make([]uint16, length+1)
	var copied uintptr
	if r, _, _ := procSendMessageTimeoutW.Call(hwnd, wmGetText, uintptr(len(buf)), uintptr(unsafe.Pointer(&buf[0])), smtoAbortIfHung, 200, uintptr(unsafe.Pointer(&copied))); r == 0 {
		return "", false
	}
	if copied > uintptr(len(buf)) {
		copied = uintptr(len(buf))
	}
	return string(utf16.Decode(buf[:copied])), true
}

// FocusedText is the text of the focused control when it is a standard Edit or RichEdit control; nil otherwise (the daemon then
// reports the delivery as unconfirmed rather than guessing).
func FocusedText() *string {
	hwnd := focusedWindow()
	if hwnd == 0 || !readableClass(className(hwnd)) {
		return nil
	}
	if s, ok := windowText(hwnd); ok {
		return &s
	}
	return nil
}

// sendInputs sends one batch and says how many events Windows took.
func sendInputs(in []input) (int, error) {
	if len(in) == 0 {
		return 0, nil
	}
	n, _, errno := procSendInput.Call(uintptr(len(in)), uintptr(unsafe.Pointer(&in[0])), inputSize)
	if int(n) != len(in) {
		return int(n), errno
	}
	return int(n), nil
}

// TypeText sends the keys for text with SendInput: Unicode key events for characters, a Return key press for each line break. A
// batch Windows does not take at all (zero events: the input was already blocked by another thread, for example BlockInput) is
// ErrBlocked. Windows does NOT report input dropped by UIPI (an app running as administrator has the focus): the count looks fine,
// which is why Probe.InputAllowed looks at the app in front before anything is typed.
func TypeText(text string) error {
	events := buildInputs(inserter.Plan(text))
	for _, group := range batch(events, 128) {
		n, err := sendInputs(group)
		if n != len(group) {
			if errors.Is(err, syscall.Errno(errorAccessDenied)) || n == 0 {
				return fmt.Errorf("%w (SendInput took %d of %d events: %v)", inserter.ErrBlocked, n, len(group), err)
			}
			return fmt.Errorf("SendInput took %d of %d events: %v", n, len(group), err)
		}
		time.Sleep(time.Millisecond) // let the target app drain its queue; also keeps a long text from flooding it
	}
	return nil
}

// Inserter types with SendInput and reads the focused Edit/RichEdit control before and after to confirm arrival.
type Inserter struct {
	// StrictUnchanged: see inserter.Flow. Off until the read-back has been proven on a real computer.
	StrictUnchanged bool
}

// Insert implements inserter.Inserter.
func (i Inserter) Insert(text string, method inserter.Method) (inserter.Outcome, error) {
	flow := inserter.Flow{
		ReadFocusedText: FocusedText,
		ReadAfter: func(text string, before *string) *string {
			if before == nil {
				return nil // unreadable field: nothing to wait for
			}
			want := inserter.NormalizeNewlines(text)
			last := FocusedText()
			for n := 0; n < 20; n++ { // up to a second; stop as soon as the text shows up
				if last != nil && *last != *before && containsNormalized(*last, want) {
					break
				}
				time.Sleep(50 * time.Millisecond)
				last = FocusedText()
			}
			return last
		},
		Type:            TypeText,
		StrictUnchanged: i.StrictUnchanged,
	}
	return flow.Run(text, method)
}

func containsNormalized(field, want string) bool {
	return strings.Contains(inserter.NormalizeNewlines(field), want)
}

// Probe answers the SystemProbe questions from Windows.
type Probe struct {
	// SkipElevationCheck turns off the look at the app in front (InputAllowed is always true): the escape hatch if that check ever
	// refuses a normal app. The send itself is unaffected.
	SkipElevationCheck bool
}

// ScreenLocked: the input desktop cannot be opened by a normal program while the lock screen, the UAC prompt or a disconnected
// session has it, so a failure to open it means typing would go nowhere.
func (Probe) ScreenLocked() bool {
	h, _, _ := procOpenInputDesktop.Call(0, 0, desktopSwitchDesktop)
	if h == 0 {
		return true
	}
	procCloseDesktop.Call(h)
	return false
}

// SecureInput: the focused control is a standard password box.
func (Probe) SecureInput() bool {
	hwnd := focusedWindow()
	if hwnd == 0 {
		return false
	}
	style, _, _ := procGetWindowLongPtrW.Call(hwnd, gwlStyle)
	return isPasswordBox(className(hwnd), style)
}

// InputAllowed: Windows lets a normal program type only into normal apps (UIPI). When the app in front runs as administrator
// SendInput is dropped, so say so instead of pretending.
func (p Probe) InputAllowed() (bool, string) {
	if p.SkipElevationCheck || processElevated(0) { // we are elevated ourselves: nothing is out of reach
		return true, ""
	}
	fg := foregroundWindow()
	if fg == 0 {
		return true, ""
	}
	var pid uint32
	procGetWindowThreadProcID.Call(fg, uintptr(unsafe.Pointer(&pid)))
	if pid == 0 {
		return true, ""
	}
	if processElevated(pid) {
		return false, "the app in front runs as administrator and Windows lets a normal program type only into normal apps"
	}
	return true, ""
}

// processElevated says whether a process (pid 0 = this one) runs elevated. When another process cannot be opened, or its token
// cannot be read, because access is denied, it is more privileged than we are, which counts as elevated. Any other failure counts
// as not elevated: the check is a hint, and a wrong "blocked" is worse than a missed one.
func processElevated(pid uint32) bool {
	var proc uintptr
	if pid == 0 {
		proc, _, _ = procGetCurrentProcess.Call()
	} else {
		h, _, err := procOpenProcess.Call(processQueryLimitedInformation, 0, uintptr(pid))
		if h == 0 {
			return errors.Is(err, syscall.Errno(errorAccessDenied))
		}
		defer procCloseHandle.Call(h)
		proc = h
	}
	var token uintptr
	if r, _, err := procOpenProcessToken.Call(proc, tokenQuery, uintptr(unsafe.Pointer(&token))); r == 0 {
		// A normal program may open the token of another normal program of the same user, not of an elevated one.
		return pid != 0 && errors.Is(err, syscall.Errno(errorAccessDenied))
	}
	defer procCloseHandle.Call(token)
	var elevation uint32
	var returned uint32
	if r, _, _ := procGetTokenInformation.Call(token, tokenElevation, uintptr(unsafe.Pointer(&elevation)), unsafe.Sizeof(elevation), uintptr(unsafe.Pointer(&returned))); r == 0 {
		return false
	}
	return elevation != 0
}

// IsElevated says whether this program runs as administrator.
func IsElevated() bool { return processElevated(0) }
