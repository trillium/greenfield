package logsvc

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Limits of GET /logs.
const (
	DefaultTail = 200
	MaxTail     = 2000
	MaxSince    = 7 * 24 * time.Hour
	MaxBytes    = 256 * 1024
)

// Query is what GET /logs asks for: the newest Tail lines, no older than Since.
type Query struct {
	Tail  int
	Since time.Duration // 0 = no limit
	// PlainText answers plain lines (format=text) instead of JSON.
	PlainText bool
}

// ParseQuery reads `tail=N` (1...2000), `since=30m` (a number and s, m, h or d; at most 7 days) and `format=json|text`. Anything else
// is an error in plain words, never a fallback to "show it".
func ParseQuery(raw string) (Query, error) {
	q := Query{Tail: DefaultTail}
	if raw == "" {
		return q, nil
	}
	for _, pair := range strings.Split(raw, "&") {
		if pair == "" {
			continue
		}
		k, v, ok := strings.Cut(pair, "=")
		if !ok {
			return q, fmt.Errorf("bad query")
		}
		switch k {
		case "tail":
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > MaxTail {
				return q, fmt.Errorf("tail must be 1 to %d", MaxTail)
			}
			q.Tail = n
		case "since":
			d, ok := ParseDuration(v)
			if !ok || d > MaxSince {
				return q, fmt.Errorf("since must look like 90s, 30m, 2h or 1d, and be at most 7d")
			}
			q.Since = d
		case "format":
			if v != "json" && v != "text" {
				return q, fmt.Errorf("format must be json or text")
			}
			q.PlainText = v == "text"
		default:
			return q, fmt.Errorf("unknown parameter %s", Token(k))
		}
	}
	return q, nil
}

// ParseDuration reads "90s", "30m", "2h", "1d"; nothing else (including zero).
func ParseDuration(s string) (time.Duration, bool) {
	if len(s) < 2 {
		return 0, false
	}
	n, err := strconv.ParseFloat(s[:len(s)-1], 64)
	if err != nil || n <= 0 || n != n {
		return 0, false
	}
	unit := map[byte]time.Duration{'s': time.Second, 'm': time.Minute, 'h': time.Hour, 'd': 24 * time.Hour}[s[len(s)-1]]
	if unit == 0 {
		return 0, false
	}
	return time.Duration(n * float64(unit)), true
}
