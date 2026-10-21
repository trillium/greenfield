package state

import (
	"sync"
	"time"
)

// Response is a remembered answer.
type Response struct {
	Status int
	Body   []byte
}

// Dedupe remembers the result of recently completed requests by id so a retried POST is answered from memory instead of typing the
// text twice. Only successes are remembered, so a request that failed (locked screen, secure input) can be retried with the same id.
type Dedupe struct {
	TTL      time.Duration
	Capacity int
	Now      func() time.Time

	mu      sync.Mutex
	entries map[string]dedupeEntry
	order   []string
}

type dedupeEntry struct {
	resp Response
	at   time.Time
}

// NewDedupe is 15 minutes and 1024 ids.
func NewDedupe() *Dedupe { return &Dedupe{TTL: 15 * time.Minute, Capacity: 1024} }

func (d *Dedupe) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

// Lookup returns the remembered answer for id.
func (d *Dedupe) Lookup(id string) (Response, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	e, ok := d.entries[id]
	if !ok {
		return Response{}, false
	}
	if d.now().Sub(e.at) > d.TTL {
		d.forget(id)
		return Response{}, false
	}
	return e.resp, true
}

// Remember stores the answer for id.
func (d *Dedupe) Remember(id string, r Response) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.entries == nil {
		d.entries = map[string]dedupeEntry{}
	}
	if _, ok := d.entries[id]; !ok {
		d.order = append(d.order, id)
	}
	d.entries[id] = dedupeEntry{resp: r, at: d.now()}
	for len(d.order) > d.Capacity {
		delete(d.entries, d.order[0])
		d.order = d.order[1:]
	}
}

func (d *Dedupe) forget(id string) {
	delete(d.entries, id)
	for i, o := range d.order {
		if o == id {
			d.order = append(d.order[:i], d.order[i+1:]...)
			break
		}
	}
}
