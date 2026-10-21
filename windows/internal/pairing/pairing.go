// Package pairing is the one-time pairing of a browser that is not on the tailnet (the PWA): the person at this computer asks for a
// short code, the browser exchanges it for a scoped token. The token is short-lived, belongs to one device, can be revoked, and
// reaches /status and /text only. Nothing secret reaches a disk: a restart of the daemon forgets every code and every token, and
// pairing again is the safe default. The Mac daemon has the same book (mac/Sources/InserterCore/Pairing.swift).
package pairing

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Limits.
const (
	CodeTTL      = 5 * time.Minute
	TokenTTL     = 24 * time.Hour
	MaxWrong     = 5
	MaxDevices   = 16
	maxNameRunes = 40
	// No 0/O/1/I/L: a code read aloud or from a screen cannot be mistyped into another valid one.
	alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
)

// Device is a paired browser. The token itself is never kept: only its SHA-256.
type Device struct {
	ID        string
	Name      string
	CreatedAt time.Time
	ExpiresAt time.Time
	LastSeen  time.Time // zero: never seen
}

// Code is what the person at the computer reads out or types into the browser.
type Code struct {
	Text      string // ABCD-EFGH
	ExpiresIn time.Duration
}

// Outcome of redeeming a code.
type Outcome int

const (
	// Paired: the token and the device are set.
	Paired Outcome = iota
	// Refused: wrong, used, expired or burned by too many wrong guesses; one answer for all of them, so a guesser learns nothing.
	Refused
	// SlowDown: too many attempts in a short time; Wait is set.
	SlowDown
)

// Result of Redeem.
type Result struct {
	Outcome Outcome
	Token   string
	Device  Device
	Wait    int // seconds, for SlowDown
}

// Book is what the daemon's routes use. Tests replace it with the real book on a fake clock, or with a fake.
type Book interface {
	IssueCode() Code
	Redeem(code, device string) Result
	// Verify returns the device that holds token, if it is valid now, and remembers that it was seen.
	Verify(token string) (Device, bool)
	Devices() []Device
	Revoke(id string) bool
	RevokeAll() int
}

// Memory is the in-memory Book.
type Memory struct {
	Now    func() time.Time
	Random func([]byte) // fills with secure random bytes; replaceable for tests only

	mu       sync.Mutex
	code     string
	codeEnds time.Time
	wrong    int
	entries  []entry
	stamps   []time.Time // redeem attempts, for the rate limit
	limit    int
	window   time.Duration
}

type entry struct {
	dev  Device
	hash [sha256.Size]byte
}

// New is a Book on the real clock and the real random source; at most 10 redeem attempts a minute over all callers.
func New() *Memory { return &Memory{limit: 10, window: time.Minute} }

// NewLimited is New with its own attempt limit, for tests.
func NewLimited(limit int, window time.Duration) *Memory {
	return &Memory{limit: limit, window: window}
}

func (m *Memory) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *Memory) fill(b []byte) {
	if m.Random != nil {
		m.Random(b)
		return
	}
	// A failure to get secure random bytes must never fall back to something guessable.
	if _, err := rand.Read(b); err != nil {
		panic("no secure random bytes")
	}
}

// Normalize is a code as compared: upper case, without spaces and dashes.
func Normalize(code string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(code) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// IssueCode makes a new code and forgets the old one: at most one is live.
func (m *Memory) IssueCode() Code {
	m.mu.Lock()
	defer m.mu.Unlock()
	// Rejection sampling: every symbol is equally likely.
	limit := 256 - (256 % len(alphabet))
	var chars []byte
	for len(chars) < 8 {
		buf := make([]byte, 16)
		m.fill(buf)
		for _, b := range buf {
			if int(b) < limit && len(chars) < 8 {
				chars = append(chars, alphabet[int(b)%len(alphabet)])
			}
		}
	}
	m.code, m.codeEnds, m.wrong = string(chars), m.now().Add(CodeTTL), 0
	return Code{Text: string(chars[:4]) + "-" + string(chars[4:]), ExpiresIn: CodeTTL}
}

// Redeem exchanges a code for a token, once.
func (m *Memory) Redeem(code, device string) Result {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	kept := m.stamps[:0]
	for _, s := range m.stamps {
		if now.Sub(s) < m.window {
			kept = append(kept, s)
		}
	}
	m.stamps = kept
	if len(m.stamps) >= m.limit {
		wait := int((m.window - now.Sub(m.stamps[0])).Seconds() + 0.999)
		if wait < 1 {
			wait = 1
		}
		return Result{Outcome: SlowDown, Wait: wait}
	}
	m.stamps = append(m.stamps, now)
	m.pruneLocked(now)
	if m.code == "" {
		return Result{Outcome: Refused}
	}
	if subtle.ConstantTimeCompare([]byte(Normalize(code)), []byte(m.code)) != 1 {
		m.wrong++
		// Enough wrong guesses burn the code: it has to be asked for again at this computer.
		if m.wrong >= MaxWrong {
			m.code = ""
		}
		return Result{Outcome: Refused}
	}
	// One use only.
	m.code = ""
	if len(m.entries) >= MaxDevices {
		m.entries = m.entries[len(m.entries)-MaxDevices+1:]
	}
	raw := make([]byte, 32)
	m.fill(raw)
	token := base64.RawURLEncoding.EncodeToString(raw)
	idBytes := make([]byte, 6)
	m.fill(idBytes)
	dev := Device{ID: hex.EncodeToString(idBytes), Name: CleanName(device), CreatedAt: now, ExpiresAt: now.Add(TokenTTL)}
	m.entries = append(m.entries, entry{dev: dev, hash: sha256.Sum256([]byte(token))})
	return Result{Outcome: Paired, Token: token, Device: dev}
}

// Verify checks a token.
func (m *Memory) Verify(token string) (Device, bool) {
	presented := sha256.Sum256([]byte(token))
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	m.pruneLocked(now)
	// Compare against every entry (there are few) so the time does not say which one matched.
	found := -1
	for i, e := range m.entries {
		if subtle.ConstantTimeCompare(presented[:], e.hash[:]) == 1 {
			found = i
		}
	}
	if found < 0 {
		return Device{}, false
	}
	m.entries[found].dev.LastSeen = now
	return m.entries[found].dev, true
}

// Devices lists the paired devices that are still valid.
func (m *Memory) Devices() []Device {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked(m.now())
	out := make([]Device, 0, len(m.entries))
	for _, e := range m.entries {
		out = append(out, e.dev)
	}
	return out
}

// Revoke ends one device's token.
func (m *Memory) Revoke(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, e := range m.entries {
		if e.dev.ID == id {
			m.entries = append(m.entries[:i], m.entries[i+1:]...)
			return true
		}
	}
	return false
}

// RevokeAll ends every token and any open code.
func (m *Memory) RevokeAll() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := len(m.entries)
	m.entries, m.code = nil, ""
	return n
}

func (m *Memory) pruneLocked(now time.Time) {
	kept := m.entries[:0]
	for _, e := range m.entries {
		if e.dev.ExpiresAt.After(now) {
			kept = append(kept, e)
		}
	}
	m.entries = kept
	if m.code != "" && !m.codeEnds.After(now) {
		m.code = ""
	}
}

// CleanName is a device name for a list: printable, one line, at most 40 characters; "browser" when nothing usable is left.
func CleanName(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if r < 0x20 || r == 0x7f {
			r = ' '
		}
		b.WriteRune(r)
	}
	s := strings.TrimSpace(b.String())
	if s == "" {
		return "browser"
	}
	if r := []rune(s); len(r) > maxNameRunes {
		s = string(r[:maxNameRunes])
	}
	return s
}

// proxyHeaders are the headers a reverse proxy adds (lowercase).
var proxyHeaders = []string{"x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip", "forwarded",
	"tailscale-user-login", "tailscale-user-name", "tailscale-funnel-request"}

// Proxied says whether a request carries a proxy header (names lowercased). Such a request did not come from the person at this
// computer even when its TCP peer is loopback (`tailscale serve`, the PWA's own server): it is never treated as local, and only a
// paired device's token lets it in.
func Proxied(headers map[string]string) bool {
	for _, h := range proxyHeaders {
		if _, ok := headers[h]; ok {
			return true
		}
	}
	return false
}
