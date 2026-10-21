package state

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

// CanInsertState is the state of the evidence that text arrives.
type CanInsertState string

const (
	StateOK      CanInsertState = "ok"
	StateFailed  CanInsertState = "failed"
	StateUnknown CanInsertState = "unknown"
)

// CanInsert is what the daemon can say about whether text really arrives, from evidence only: a delivery it confirmed by reading the
// focused field back, or a selftest that read its own window.
type CanInsert struct {
	State  CanInsertState
	At     *time.Time
	Source string // "delivery" or "selftest"
	Detail string
}

// JSON is the `evidence` object of GET /status.
func (c CanInsert) JSON() map[string]any {
	o := map[string]any{"state": string(c.State), "detail": c.Detail}
	if c.At != nil {
		o["at"] = c.At.UTC().Format(time.RFC3339)
	}
	if c.Source != "" {
		o["source"] = c.Source
	}
	return o
}

// DeliveryLedger remembers the latest success and failure in a small file shared by the daemon and the selftest. Evidence older
// than the daemon's start does not count (a reinstall may have changed what is allowed), nor does evidence older than a week.
type DeliveryLedger struct {
	File        string
	DaemonStart time.Time
	Now         func() time.Time
	mu          sync.Mutex
}

// MaxEvidenceAge is how long a success or failure counts.
const MaxEvidenceAge = 7 * 24 * time.Hour

type entry struct {
	At     time.Time `json:"at"`
	Source string    `json:"source"`
	Detail string    `json:"detail"`
}
type ledgerFile struct {
	Success *entry `json:"success,omitempty"`
	Failure *entry `json:"failure,omitempty"`
}

func (d *DeliveryLedger) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

func (d *DeliveryLedger) load() ledgerFile {
	var f ledgerFile
	if data, err := os.ReadFile(d.File); err == nil {
		_ = json.Unmarshal(data, &f)
	}
	return f
}

func (d *DeliveryLedger) save(f ledgerFile) {
	if data, err := json.Marshal(f); err == nil {
		_ = writeAtomic(d.File, data)
	}
}

// RecordSuccess notes that text was read back from the focused field.
func (d *DeliveryLedger) RecordSuccess(source string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	f := d.load()
	f.Success = &entry{At: d.now().UTC(), Source: source, Detail: "text was read back from the focused field"}
	d.save(f)
}

// RecordFailure notes that text provably did not arrive.
func (d *DeliveryLedger) RecordFailure(source, detail string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	f := d.load()
	f.Failure = &entry{At: d.now().UTC(), Source: source, Detail: detail}
	d.save(f)
}

// CanInsert is the newest valid evidence.
func (d *DeliveryLedger) CanInsert() CanInsert {
	d.mu.Lock()
	defer d.mu.Unlock()
	f := d.load()
	valid := func(e *entry) *entry {
		if e == nil || e.At.Before(d.DaemonStart) || d.now().Sub(e.At) > MaxEvidenceAge {
			return nil
		}
		return e
	}
	ok, bad := valid(f.Success), valid(f.Failure)
	if bad != nil && (ok == nil || bad.At.After(ok.At)) {
		return CanInsert{State: StateFailed, At: &bad.At, Source: bad.Source, Detail: bad.Detail}
	}
	if ok != nil {
		return CanInsert{State: StateOK, At: &ok.At, Source: ok.Source, Detail: ok.Detail}
	}
	return CanInsert{State: StateUnknown, Detail: "no delivery has been confirmed since this daemon started"}
}
