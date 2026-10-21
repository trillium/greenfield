// Package compat is the version rule between the app and the daemon (docs/mac-contract.md): while MAJOR is 0 the MINOR must
// match; from 1.0.0 the MAJOR must match; each side also names the oldest peer it works with.
package compat

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Semver is MAJOR.MINOR.PATCH.
type Semver struct{ Major, Minor, Patch int }

func (s Semver) String() string { return fmt.Sprintf("%d.%d.%d", s.Major, s.Minor, s.Patch) }

// Less orders versions.
func (s Semver) Less(o Semver) bool {
	if s.Major != o.Major {
		return s.Major < o.Major
	}
	if s.Minor != o.Minor {
		return s.Minor < o.Minor
	}
	return s.Patch < o.Patch
}

// Parse accepts "1.2.3", "v1.2.3" and "1.2.3+4.gabc" (build metadata is ignored); anything else is not a version.
func Parse(text string) (Semver, bool) {
	t := strings.TrimSpace(text)
	t = strings.TrimPrefix(t, "v")
	if i := strings.IndexByte(t, '+'); i >= 0 {
		t = t[:i]
	}
	parts := strings.Split(t, ".")
	if len(parts) != 3 {
		return Semver{}, false
	}
	var n [3]int
	for i, p := range parts {
		if p == "" {
			return Semver{}, false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return Semver{}, false
			}
		}
		v, err := strconv.Atoi(p)
		if err != nil {
			return Semver{}, false
		}
		n[i] = v
	}
	return Semver{n[0], n[1], n[2]}, true
}

// Verdict is the result of judging a peer.
type Verdict int

const (
	Compatible Verdict = iota
	// PeerTooOld: the peer is older than our minimum, or on an older line than us.
	PeerTooOld
	// PeerTooNew: the peer is on a newer line than us.
	PeerTooNew
	PeerUnreadable
)

// SameLine says whether two versions are on one line of the rule.
func SameLine(a, b Semver) bool {
	if a.Major != b.Major {
		return false
	}
	if a.Major == 0 {
		return a.Minor == b.Minor
	}
	return true
}

// Judge applies the rule to a peer's version.
func Judge(peer, me, minPeer string) Verdict {
	p, ok1 := Parse(peer)
	m, ok2 := Parse(me)
	floor, ok3 := Parse(minPeer)
	if !ok1 || !ok2 || !ok3 {
		return PeerUnreadable
	}
	if p.Less(floor) {
		return PeerTooOld
	}
	if SameLine(p, m) {
		return Compatible
	}
	if p.Less(m) {
		return PeerTooOld
	}
	return PeerTooNew
}

// Sighting is one app version the daemon has seen, and when.
type Sighting struct {
	Version string    `json:"version"`
	At      time.Time `json:"at"`
}

// AppCompat is the daemon's view of the newest app it has seen (`app_compatible` in GET /status).
type AppCompat struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Fix     string `json:"fix"`
}

// Evaluate judges the newest app seen. No app yet is a note, never a failure.
func Evaluate(seen []Sighting, me, minClient string, now time.Time) AppCompat {
	if len(seen) == 0 {
		return AppCompat{OK: true, Message: "no app has connected yet"}
	}
	newest := seen[0]
	for _, s := range seen {
		if s.At.After(newest.At) {
			newest = s
		}
	}
	age := AgeText(newest.At, now)
	switch Judge(newest.Version, me, minClient) {
	case Compatible:
		return AppCompat{OK: true, Message: fmt.Sprintf("the newest app seen (%s, %s) is compatible with daemon %s", newest.Version, age, me)}
	case PeerTooOld:
		return AppCompat{Message: fmt.Sprintf("the newest app seen (%s, %s) is older than this daemon works with (daemon %s, oldest app %s)", newest.Version, age, me, minClient),
			Fix: fmt.Sprintf("Update the app on the phone to a version on the same line as %s.", me)}
	case PeerTooNew:
		return AppCompat{Message: fmt.Sprintf("the newest app seen (%s, %s) is newer than this daemon (%s) supports", newest.Version, age, me),
			Fix: "Update the daemon on this computer: build the repository's windows/ folder again (`make windows`) and replace greenfield-inserter.exe."}
	default:
		return AppCompat{Message: fmt.Sprintf("the newest app seen sent a version this daemon cannot read (\"%s\")", newest.Version),
			Fix: "Update the app on the phone."}
	}
}

// AgeText says how long ago something was, in the words health and the status use.
func AgeText(from, to time.Time) string {
	s := int(to.Sub(from).Seconds())
	switch {
	case s < 90:
		if s < 0 {
			s = 0
		}
		return fmt.Sprintf("%d seconds ago", s)
	case s < 5400:
		return fmt.Sprintf("%d minutes ago", s/60)
	case s < 172800:
		return fmt.Sprintf("%d hours ago", s/3600)
	default:
		return fmt.Sprintf("%d days ago", s/86400)
	}
}
