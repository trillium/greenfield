//go:build !windows

package winsys

import (
	"errors"

	"greenfield-inserter/internal/inserter"
)

// ErrNotWindows is what typing says on any other system: this program only types on Windows.
var ErrNotWindows = errors.New("this build can only type on Windows")

// Inserter cannot type here.
type Inserter struct{ StrictUnchanged bool }

// Insert implements inserter.Inserter.
func (Inserter) Insert(string, inserter.Method) (inserter.Outcome, error) {
	return inserter.Outcome{}, ErrNotWindows
}

// Probe reports a computer that is unlocked and allowed, so the status routes can be exercised on any system.
type Probe struct{ SkipElevationCheck bool }

func (Probe) ScreenLocked() bool           { return false }
func (Probe) SecureInput() bool            { return false }
func (Probe) InputAllowed() (bool, string) { return true, "" }

// FocusedText has no focused control here.
func FocusedText() *string { return nil }

// IsElevated is false here.
func IsElevated() bool { return false }
