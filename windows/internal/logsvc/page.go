package logsvc

import (
	"os"
	"regexp"
	"sync"
	"time"
)

// Page is the answer to a log query.
type Page struct {
	Lines     []string
	Bytes     int
	Truncated bool
}

// BuildPage redacts the lines and keeps at most MaxBytes of them, newest kept.
func BuildPage(lines []string, q Query) Page {
	safe := RedactLines(lines)
	bytes := 0
	for _, l := range safe {
		bytes += len(l) + 1
	}
	truncated := len(lines) >= q.Tail
	for bytes > MaxBytes && len(safe) > 0 {
		bytes -= len(safe[0]) + 1
		safe = safe[1:]
		truncated = true
	}
	if safe == nil {
		safe = []string{}
	}
	return Page{Lines: safe, Bytes: bytes, Truncated: truncated}
}

var (
	idRe     = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	sourceRe = regexp.MustCompile(`^[a-z0-9_-]{1,16}$`)
	tokenRe  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,16}$`)
)

// ID is an id as a log field: letters, digits, dash and underscore up to 64 characters, else "(invalid)".
func ID(v string) string { return pick(idRe, v, "(invalid)") }

// SourceLabel is a source label: lowercase letters, digits, dash and underscore up to 16 characters, else "other".
func SourceLabel(v string) string { return pick(sourceRe, v, "other") }

// Token is a short word from a request (a parameter name): up to 16 letters, digits, dash, underscore; else "?".
func Token(v string) string { return pick(tokenRe, v, "?") }

// Path is the path of a request as the daemon knows it; any other path is logged as "(unknown)".
func Path(v string, known map[string]bool) string {
	if known[v] {
		return v
	}
	return "(unknown)"
}

func pick(re *regexp.Regexp, v, otherwise string) string {
	if re.MatchString(v) {
		return v
	}
	return otherwise
}

// Logger appends timestamped lines to a file (and optionally stderr) with simple size-based rotation. Callers only ever pass
// metadata; inserted text is never handed to a logger.
type Logger struct {
	File     string // "" = no file
	Echo     func(string)
	MaxBytes int64
	Now      func() time.Time
	mu       sync.Mutex
}

// NewLogger writes to file, rotating at 2 MiB.
func NewLogger(file string, echo func(string)) *Logger {
	return &Logger{File: file, Echo: echo, MaxBytes: 2 << 20, Now: time.Now}
}

// Log writes one line.
func (l *Logger) Log(message string) {
	line := l.Now().UTC().Format(time.RFC3339) + " " + message + "\n"
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.Echo != nil {
		l.Echo(line)
	}
	if l.File == "" {
		return
	}
	if st, err := os.Stat(l.File); err == nil && st.Size() > l.MaxBytes {
		os.Remove(l.File + ".1")
		os.Rename(l.File, l.File+".1")
	}
	f, err := os.OpenFile(l.File, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.WriteString(line)
	f.Close()
}
