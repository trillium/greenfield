//go:build !windows

package winsys

import "errors"

// TestField is the window the selftest types into. It exists only on Windows.
type TestField struct{}

func (*TestField) Open() error          { return errors.New("the selftest window exists only on Windows") }
func (*TestField) Focused() bool        { return false }
func (*TestField) Text() (string, bool) { return "", false }
func (*TestField) Close()               {}
