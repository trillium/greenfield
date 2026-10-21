package logsvc

import (
	"os"
	"strings"
	"sync"
	"time"
)

// Source is where the daemon's own log lines come from.
type Source interface {
	// Read returns the newest lines (oldest of them first), already limited to the query. Not redacted.
	Read(q Query, now time.Time) []string
	// Available says whether there is a log to serve at all.
	Available() bool
}

// FileSource reads the file Logger writes and the one it rotated away, never loading more than Window bytes of either.
type FileSource struct {
	File   string
	Window int64
}

// NewFileSource reads file with a 1 MiB window.
func NewFileSource(file string) *FileSource { return &FileSource{File: file, Window: 1 << 20} }

// Available implements Source.
func (s *FileSource) Available() bool {
	f, err := os.Open(s.File)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// Read implements Source.
func (s *FileSource) Read(q Query, now time.Time) []string {
	lines := tailLines(s.File, s.Window)
	if len(lines) < q.Tail {
		lines = append(tailLines(s.File+".1", s.Window), lines...)
	}
	if q.Since > 0 {
		cutoff := now.Add(-q.Since)
		keeping := false
		kept := lines[:0:0]
		for _, line := range lines {
			if first, _, _ := strings.Cut(line, " "); first != "" {
				if t, err := time.Parse(time.RFC3339, first); err == nil {
					keeping = !t.Before(cutoff)
				}
			}
			if keeping { // a line without a timestamp belongs to the line before it
				kept = append(kept, line)
			}
		}
		lines = kept
	}
	if len(lines) > q.Tail {
		lines = lines[len(lines)-q.Tail:]
	}
	return lines
}

func tailLines(path string, window int64) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil
	}
	start := int64(0)
	if st.Size() > window {
		start = st.Size() - window
	}
	buf := make([]byte, st.Size()-start)
	if _, err := f.ReadAt(buf, start); err != nil && len(buf) > 0 {
		return nil
	}
	text := string(buf)
	if start > 0 { // drop the cut-off first line
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			text = text[i+1:]
		}
	}
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if l = strings.TrimRight(l, "\r"); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// RateLimiter admits at most Limit successful requests per Window over all callers: logs are for a person debugging, not a feed.
type RateLimiter struct {
	Limit  int
	Window time.Duration
	mu     sync.Mutex
	stamps []time.Time
}

// NewRateLimiter is 6 per minute.
func NewRateLimiter() *RateLimiter { return &RateLimiter{Limit: 6, Window: time.Minute} }

// Admit returns 0 when the request is allowed (and counted); otherwise the seconds to wait.
func (r *RateLimiter) Admit(now time.Time) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.stamps[:0]
	for _, s := range r.stamps {
		if now.Sub(s) < r.Window {
			kept = append(kept, s)
		}
	}
	r.stamps = kept
	if len(r.stamps) >= r.Limit {
		wait := int((r.Window - now.Sub(r.stamps[0])).Seconds() + 0.999)
		if wait < 1 {
			wait = 1
		}
		return wait
	}
	r.stamps = append(r.stamps, now)
	return 0
}
