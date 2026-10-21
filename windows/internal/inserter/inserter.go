// Package inserter is everything about putting text into the focused field that does not need Windows: line endings, the plan of
// key events, and the reading of what a read-back proves. The Win32 calls live behind these interfaces in internal/winsys, so all of
// it is tested with fakes.
package inserter

import (
	"errors"
	"strings"
	"unicode/utf16"
)

// Method says how text is put in. Windows has one way, Unicode key events (SendInput); "paste" is accepted for the
// phone's contract and answered as "type".
type Method string

const (
	Paste Method = "paste"
	Type  Method = "type"
)

// Delivery is what the daemon can prove about arrival.
type Delivery string

const (
	// Confirmed: the focused field was read before and after and now holds the text.
	Confirmed Delivery = "confirmed"
	// Unconfirmed: the keys were sent but the target does not expose its text, so arrival cannot be checked.
	Unconfirmed Delivery = "unconfirmed"
)

// Outcome is a successful insertion.
type Outcome struct {
	Method   Method
	Delivery Delivery
}

// Errors an Inserter returns; anything else is an insert_failed (HTTP 500).
var (
	// ErrBlocked: Windows refused the input (an app running as administrator has the focus, or another desktop is active).
	ErrBlocked = errors.New("input blocked by Windows")
	// ErrNotDelivered: the focused field could be read and the text did not appear in it.
	ErrNotDelivered = errors.New("not delivered")
)

// Inserter puts text at the cursor of the focused app. method nil/empty means the default.
type Inserter interface {
	Insert(text string, method Method) (Outcome, error)
}

// NormalizeNewlines turns every line ending a client or a field might use (CRLF, a lone CR, VT, FF, NEL, the Unicode line and
// paragraph separators) into one line feed. Nothing else changes: empty lines and a trailing newline stay.
func NormalizeNewlines(text string) string {
	if !strings.ContainsAny(text, "\n\r\v\f\u0085  ") {
		return text
	}
	var b strings.Builder
	b.Grow(len(text))
	rs := []rune(text)
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		switch r {
		case '\r':
			if i+1 < len(rs) && rs[i+1] == '\n' {
				i++
			}
			b.WriteByte('\n')
		case '\n', '\v', '\f', '\u0085', ' ', ' ':
			b.WriteByte('\n')
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Key is one key press to send: a Unicode code unit typed as a character, or the Return key.
type Key struct {
	Return bool
	// Unit is a UTF-16 code unit, sent with KEYEVENTF_UNICODE (a surrogate pair is two keys, in order).
	Unit uint16
}

// Plan is the keys that type text: line by line with a Return key press between lines, so a line break is never part of a typed
// string. A trailing newline is a final Return, an empty line is two Returns in a row, and a bare newline is one Return. NUL is
// dropped (it cannot be typed).
func Plan(text string) []Key {
	var keys []Key
	for i, line := range strings.Split(NormalizeNewlines(text), "\n") {
		if i > 0 {
			keys = append(keys, Key{Return: true})
		}
		for _, u := range utf16.Encode([]rune(line)) {
			if u == 0 {
				continue
			}
			keys = append(keys, Key{Unit: u})
		}
	}
	return keys
}

// Evidence is what the before and after text of the focused field proves.
type Evidence int

const (
	EvidenceConfirmed Evidence = iota
	EvidenceUnconfirmed
	EvidenceNotDelivered
)

// JudgeDelivery decides what the before and after text of the focused field proves. nil means unreadable. Text is compared with its
// newlines (in whatever line ending the field uses), so words that arrived without their line breaks are not proof.
func JudgeDelivery(before, after *string, text string) Evidence {
	sent := NormalizeNewlines(text)
	// A bare Return or whitespace is a key press, not text: it may leave the field's contents unchanged (a single-line field
	// submits instead), so unchanged proves nothing.
	if strings.TrimSpace(sent) == "" {
		return EvidenceUnconfirmed
	}
	if before == nil || after == nil {
		return EvidenceUnconfirmed
	}
	was, now := NormalizeNewlines(*before), NormalizeNewlines(*after)
	if now == was {
		// A final Return can submit and clear a one-line field, leaving it as it was.
		if strings.HasSuffix(sent, "\n") {
			return EvidenceUnconfirmed
		}
		return EvidenceNotDelivered
	}
	// Something changed: it only counts as proof if our text is in there (apps may rewrite it).
	if strings.Contains(now, sent) {
		return EvidenceConfirmed
	}
	return EvidenceUnconfirmed
}

// Flow is the order of attempts and what each outcome means, with the OS pieces injected so it can be tested.
type Flow struct {
	// ReadFocusedText is the text of the focused field, nil if the focused control does not expose it.
	ReadFocusedText func() *string
	// ReadAfter waits for the field to show text (polling) and returns its last reading.
	ReadAfter func(text string, before *string) *string
	// Type sends the keys.
	Type func(text string) error
	// StrictUnchanged makes "the field was readable and did not change" a ErrNotDelivered (HTTP 502). Off by default on Windows: the
	// read-back of a foreign window is unproven on a real computer, and a false 502 would make the phone resend text that did arrive.
	// With it off, an unchanged field is reported as unconfirmed.
	StrictUnchanged bool
}

// Run never returns an outcome without having sent the keys.
func (f Flow) Run(text string, _ Method) (Outcome, error) {
	before := f.ReadFocusedText()
	if err := f.Type(text); err != nil {
		return Outcome{}, err
	}
	var after *string
	if f.ReadAfter != nil {
		after = f.ReadAfter(text, before)
	}
	switch JudgeDelivery(before, after, text) {
	case EvidenceConfirmed:
		return Outcome{Method: Type, Delivery: Confirmed}, nil
	case EvidenceNotDelivered:
		if f.StrictUnchanged {
			return Outcome{}, ErrNotDelivered
		}
		return Outcome{Method: Type, Delivery: Unconfirmed}, nil
	default:
		return Outcome{Method: Type, Delivery: Unconfirmed}, nil
	}
}
