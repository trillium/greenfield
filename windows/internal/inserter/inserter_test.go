package inserter

import (
	"errors"
	"reflect"
	"testing"
)

func TestNormalizeNewlines(t *testing.T) {
	cases := map[string]string{
		"a\r\nb":           "a\nb",
		"a\rb":             "a\nb",
		"a\nb":             "a\nb",
		"a b c":            "a\nb\nc",
		"a\u0085b":         "a\nb",
		"a\v\fb":           "a\n\nb",
		"a\r\n\r\nb\r\n":   "a\n\nb\n",
		"no breaks":        "no breaks",
		"\n":               "\n",
		"a\n\rb":           "a\n\nb",
		"tail\r":           "tail\n",
		"héllo 🎤\r\nworld": "héllo 🎤\nworld",
	}
	for in, want := range cases {
		if got := NormalizeNewlines(in); got != want {
			t.Errorf("NormalizeNewlines(%q) = %q, want %q", in, got, want)
		}
	}
}

func units(s string) []Key {
	var k []Key
	for _, r := range s {
		k = append(k, Key{Unit: uint16(r)})
	}
	return k
}

func TestPlanKeepsEveryLineBreakAsOneReturn(t *testing.T) {
	ret := Key{Return: true}
	cases := []struct {
		text string
		want []Key
	}{
		{"hi", units("hi")},
		{"\n", []Key{ret}},
		{"a\nb", append(append(units("a"), ret), units("b")...)},
		{"a\n", append(units("a"), ret)},
		{"a\n\nb", append(append(append(units("a"), ret), ret), units("b")...)},
		{"a\r\nb", append(append(units("a"), ret), units("b")...)},
		{"Dear team,\n\nThe build is green.\nThanks\n", nil},
	}
	for _, c := range cases[:6] {
		if got := Plan(c.text); !reflect.DeepEqual(got, c.want) {
			t.Errorf("Plan(%q) = %v, want %v", c.text, got, c.want)
		}
	}
	// The multi-line sample from the phone's fixture: 4 line breaks = 4 Returns, and no typed character is a line break.
	returns, typed := 0, 0
	for _, k := range Plan(cases[6].text) {
		if k.Return {
			returns++
		} else {
			typed++
			if k.Unit == '\n' || k.Unit == '\r' {
				t.Fatalf("a line break was typed as a character")
			}
		}
	}
	if returns != 4 || typed != len("Dear team,The build is green.Thanks") {
		t.Errorf("returns=%d typed=%d", returns, typed)
	}
}

func TestPlanSendsSurrogatePairsInOrderAndDropsNUL(t *testing.T) {
	got := Plan("a🎤\x00b")
	want := []Key{{Unit: 'a'}, {Unit: 0xD83C}, {Unit: 0xDFA4}, {Unit: 'b'}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func p(s string) *string { return &s }

func TestJudgeDelivery(t *testing.T) {
	cases := []struct {
		name          string
		before, after *string
		text          string
		want          Evidence
	}{
		{"arrived", p("x"), p("xhello"), "hello", EvidenceConfirmed},
		{"arrived with line break in the field's own ending", p(""), p("a\r\nb"), "a\nb", EvidenceConfirmed},
		{"words without their breaks are not proof", p(""), p("ab"), "a\nb", EvidenceUnconfirmed},
		{"unchanged readable field", p("x"), p("x"), "hello", EvidenceNotDelivered},
		{"unchanged but ends with a Return", p("x"), p("x"), "hello\n", EvidenceUnconfirmed},
		{"unreadable before", nil, p("x"), "hello", EvidenceUnconfirmed},
		{"unreadable after", p("x"), nil, "hello", EvidenceUnconfirmed},
		{"a bare Return proves nothing", p("x"), p("x"), "\n", EvidenceUnconfirmed},
		{"whitespace proves nothing", p("x"), p("x"), "  ", EvidenceUnconfirmed},
		{"rewritten by the app", p("x"), p("something else"), "hello", EvidenceUnconfirmed},
	}
	for _, c := range cases {
		if got := JudgeDelivery(c.before, c.after, c.text); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func flow(before, after *string, typeErr error, strict bool) (Flow, *int) {
	typed := 0
	return Flow{
		ReadFocusedText: func() *string { return before },
		ReadAfter:       func(string, *string) *string { return after },
		Type:            func(string) error { typed++; return typeErr },
		StrictUnchanged: strict,
	}, &typed
}

func TestFlowConfirmsOnlyWhatItCanRead(t *testing.T) {
	f, typed := flow(p(""), p("hello"), nil, false)
	out, err := f.Run("hello", "")
	if err != nil || out.Delivery != Confirmed || out.Method != Type || *typed != 1 {
		t.Fatalf("got %+v %v typed=%d", out, err, *typed)
	}
	f, _ = flow(nil, nil, nil, false)
	if out, err = f.Run("hello", Paste); err != nil || out.Delivery != Unconfirmed || out.Method != Type {
		t.Fatalf("unreadable: got %+v %v", out, err)
	}
}

func TestFlowUnchangedFieldIsUnconfirmedUnlessStrict(t *testing.T) {
	f, _ := flow(p("x"), p("x"), nil, false)
	if out, err := f.Run("hello", ""); err != nil || out.Delivery != Unconfirmed {
		t.Fatalf("lenient: got %+v %v", out, err)
	}
	f, typed := flow(p("x"), p("x"), nil, true)
	if _, err := f.Run("hello", ""); !errors.Is(err, ErrNotDelivered) || *typed != 1 {
		t.Fatalf("strict: got %v typed=%d", err, *typed)
	}
}

func TestFlowPassesTypingErrorsThrough(t *testing.T) {
	f, _ := flow(p(""), p(""), ErrBlocked, false)
	if _, err := f.Run("hello", ""); !errors.Is(err, ErrBlocked) {
		t.Fatalf("got %v", err)
	}
}
