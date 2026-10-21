package state

import (
	"os"
	"strings"
)

// NameStore is the computer's display name: its host name unless changed with `name set`.
type NameStore struct {
	File     string
	Hostname func() (string, error)
}

// Current is the name the phone shows.
func (n NameStore) Current() string {
	if data, err := os.ReadFile(n.File); err == nil {
		if s := strings.TrimSpace(string(data)); s != "" {
			return s
		}
	}
	host := os.Hostname
	if n.Hostname != nil {
		host = n.Hostname
	}
	if h, err := host(); err == nil && h != "" {
		return h
	}
	return "Windows computer"
}

// Set stores a name (trimmed, at most 60 characters, one line).
func (n NameStore) Set(name string) error {
	name = strings.Join(strings.Fields(name), " ")
	if r := []rune(name); len(r) > 60 {
		name = string(r[:60])
	}
	if name == "" {
		return os.ErrInvalid
	}
	return writeAtomic(n.File, []byte(name+"\n"))
}

// Clear goes back to the host name.
func (n NameStore) Clear() error {
	err := os.Remove(n.File)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
