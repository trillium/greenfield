package winsys

import (
	"testing"
	"unsafe"

	"greenfield-inserter/internal/inserter"
)

func TestInputRecordIsFortyBytesLikeWin32OnSixtyFourBit(t *testing.T) {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		t.Skip("windows/amd64 and windows/arm64 are the shipped targets")
	}
	if got := unsafe.Sizeof(input{}); got != inputSize {
		t.Fatalf("sizeof(INPUT) = %d, SendInput needs %d", got, inputSize)
	}
	var in input
	if off := unsafe.Offsetof(in.ki); off != 8 {
		t.Errorf("the union starts at offset %d, Win32 puts it at 8", off)
	}
	if got := unsafe.Sizeof(keybdInput{}); got != 24 {
		t.Errorf("sizeof(KEYBDINPUT) = %d, want 24", got)
	}
	if off := unsafe.Offsetof(in.ki.dwExtraInfo); off != 16 {
		t.Errorf("dwExtraInfo at %d, Win32 puts it at 16", off)
	}
}

func TestBuildInputsTypesCharactersAsUnicodeAndLineBreaksAsReturn(t *testing.T) {
	in := buildInputs(inserter.Plan("a\nb"))
	if len(in) != 6 {
		t.Fatalf("3 keys = 6 events, got %d", len(in))
	}
	check := func(i int, vk, scan uint16, flags uint32) {
		t.Helper()
		k := in[i].ki
		if in[i].typ != inputKeyboard || k.wVk != vk || k.wScan != scan || k.dwFlags != flags {
			t.Errorf("event %d = %+v", i, in[i])
		}
	}
	check(0, 0, 'a', keyeventfUnicode)
	check(1, 0, 'a', keyeventfUnicode|keyeventfKeyUp)
	check(2, vkReturn, scanReturn, 0)
	check(3, vkReturn, scanReturn, keyeventfKeyUp)
	check(4, 0, 'b', keyeventfUnicode)
	check(5, 0, 'b', keyeventfUnicode|keyeventfKeyUp)
}

func TestSurrogatePairsAreTwoUnicodeKeysInOrder(t *testing.T) {
	in := buildInputs(inserter.Plan("🎤")) // U+1F3A4 = D83C DFA4
	if len(in) != 4 || in[0].ki.wScan != 0xD83C || in[2].ki.wScan != 0xDFA4 {
		t.Errorf("%+v", in)
	}
}

func TestBatchNeverSeparatesDownFromUp(t *testing.T) {
	in := buildInputs(inserter.Plan("abcdefg")) // 14 events
	got := batch(in, 5)                         // rounds down to 4
	total := 0
	for _, b := range got {
		if len(b)%2 != 0 || len(b) > 4 {
			t.Errorf("batch of %d", len(b))
		}
		for i := 0; i+1 < len(b); i += 2 {
			if b[i].ki.dwFlags&keyeventfKeyUp != 0 || b[i+1].ki.dwFlags&keyeventfKeyUp == 0 {
				t.Errorf("down/up pairing broken")
			}
		}
		total += len(b)
	}
	if total != 14 || len(got) != 4 {
		t.Errorf("total %d in %d batches", total, len(got))
	}
	if len(batch(nil, 8)) != 0 {
		t.Errorf("nothing to send")
	}
}

func TestReadableClassesAndPasswordBoxes(t *testing.T) {
	for class, want := range map[string]bool{"Edit": true, "RichEdit20W": true, "RICHEDIT50W": true, "RichEditD2DPT": true, "Chrome_RenderWidgetHostHWND": false, "Scintilla": false, "": false, "Rich": false} {
		if readableClass(class) != want {
			t.Errorf("readableClass(%q) = %v", class, !want)
		}
	}
	if !isPasswordBox("Edit", esPassword|wsVisible) || isPasswordBox("Edit", wsVisible) || isPasswordBox("Chrome_WidgetWin_1", esPassword) {
		t.Errorf("password box detection")
	}
}
