// Package winsys is the only place that touches Win32: SendInput to type, GetGUIThreadInfo and WM_GETTEXT to read a field back,
// OpenInputDesktop to see the lock screen, and a few more. Everything that can be decided without Windows (the INPUT records for a
// text, how a probe's facts become answers) is in files that build and are tested everywhere; the calls are in *_windows.go files
// behind small interfaces, and a stub for other systems keeps the daemon buildable and testable on a Mac.
package winsys

import "greenfield-inserter/internal/inserter"

// Win32 constants used by the typing code.
const (
	inputKeyboard = 1

	keyeventfKeyUp   = 0x0002
	keyeventfUnicode = 0x0004

	vkReturn = 0x0D
	// scanReturn is the scan code of Return (MapVirtualKey(VK_RETURN, MAPVK_VK_TO_VSC)); apps that read the scan code get a real key.
	scanReturn = 0x1C
)

// keybdInput is KEYBDINPUT.
type keybdInput struct {
	wVk         uint16
	wScan       uint16
	dwFlags     uint32
	time        uint32
	dwExtraInfo uintptr
}

// input is INPUT for a keyboard event: a type, then a union that is as large as MOUSEINPUT. On the 64-bit systems this ships for
// (windows/amd64 and windows/arm64) it is 40 bytes, which SendInput checks as cbSize; layout_test.go pins that.
type input struct {
	typ uint32
	ki  keybdInput
	_   [8]byte
}

// inputSize is sizeof(INPUT).
const inputSize = 40

// buildInputs turns a plan into INPUT records: each typed character is a key down and a key up with KEYEVENTF_UNICODE (wVk 0, the
// UTF-16 unit in wScan, so a surrogate pair is two events in order) and each line break is a real Return key press.
func buildInputs(keys []inserter.Key) []input {
	out := make([]input, 0, len(keys)*2)
	for _, k := range keys {
		var down, up keybdInput
		if k.Return {
			down = keybdInput{wVk: vkReturn, wScan: scanReturn}
			up = keybdInput{wVk: vkReturn, wScan: scanReturn, dwFlags: keyeventfKeyUp}
		} else {
			down = keybdInput{wScan: k.Unit, dwFlags: keyeventfUnicode}
			up = keybdInput{wScan: k.Unit, dwFlags: keyeventfUnicode | keyeventfKeyUp}
		}
		out = append(out, input{typ: inputKeyboard, ki: down}, input{typ: inputKeyboard, ki: up})
	}
	return out
}

// batch splits inputs into groups of at most n events, never separating a key down from its key up.
func batch(inputs []input, n int) [][]input {
	if n < 2 {
		n = 2
	}
	n -= n % 2
	var out [][]input
	for len(inputs) > 0 {
		m := n
		if len(inputs) < m {
			m = len(inputs)
		}
		out = append(out, inputs[:m])
		inputs = inputs[m:]
	}
	return out
}

// Classes of the focused control whose text can be read back with WM_GETTEXT. Everything else is "unreadable", and the daemon then
// says "unconfirmed" instead of guessing.
func readableClass(class string) bool {
	switch {
	case class == "Edit", class == "EDIT":
		return true
	case len(class) >= 8 && (class[:8] == "RichEdit" || class[:8] == "RICHEDIT"):
		return true
	}
	return false
}

const (
	esPassword = 0x0020
	wsVisible  = 0x10000000
)

// isPasswordBox says whether a focused control is a standard password box: an Edit control with ES_PASSWORD. Password fields of
// browsers and other toolkits draw themselves and cannot be recognised from outside; for those the daemon does not know.
func isPasswordBox(class string, style uintptr) bool {
	return (class == "Edit" || class == "EDIT") && style&esPassword != 0
}
