// Package state is what the daemon remembers between requests and restarts: the apps it has seen, the evidence that text really
// arrives, the ids it has already typed and the computer's display name. Files live in one per-user directory.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"greenfield-inserter/internal/compat"
)

// Paths are the daemon's files.
type Paths struct{ Dir string }

// Standard is %AppData%\greenfield-inserter on Windows; GREENFIELD_INSERTER_HOME overrides it (tests, a second daemon).
func Standard() Paths {
	if d := os.Getenv("GREENFIELD_INSERTER_HOME"); d != "" {
		return Paths{Dir: d}
	}
	base, err := os.UserConfigDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	return Paths{Dir: filepath.Join(base, "greenfield-inserter")}
}

func (p Paths) LogFile() string      { return filepath.Join(p.Dir, "inserter.log") }
func (p Paths) ClientsFile() string  { return filepath.Join(p.Dir, "clients.json") }
func (p Paths) DeliveryFile() string { return filepath.Join(p.Dir, "delivery.json") }
func (p Paths) NameFile() string     { return filepath.Join(p.Dir, "name") }

// EnsureDir creates the directory.
func (p Paths) EnsureDir() error { return os.MkdirAll(p.Dir, 0o700) }

// writeAtomic writes data to path through a temporary file, so a reader never sees half a file.
func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ClientLedger remembers the last few distinct app versions that talked to the daemon, in a small file so the memory survives
// restarts and `health`, run as another process, can read it.
type ClientLedger struct {
	File string
	Now  func() time.Time
	mu   sync.Mutex
}

const keepClients = 5

func (c *ClientLedger) load() []compat.Sighting {
	data, err := os.ReadFile(c.File)
	if err != nil {
		return nil
	}
	var all []compat.Sighting
	if json.Unmarshal(data, &all) != nil {
		return nil
	}
	return all
}

// Saw records an app version, newest first, one entry per version.
func (c *ClientLedger) Saw(version string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(version) > 40 {
		version = version[:40]
	}
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	all := []compat.Sighting{{Version: version, At: now().UTC()}}
	for _, s := range c.load() {
		if s.Version != version {
			all = append(all, s)
		}
	}
	if len(all) > keepClients {
		all = all[:keepClients]
	}
	if data, err := json.Marshal(all); err == nil {
		_ = writeAtomic(c.File, data)
	}
}

// Recent is the sightings, newest first.
func (c *ClientLedger) Recent() []compat.Sighting {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.load()
}
