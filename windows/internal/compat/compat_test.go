package compat

import (
	"strings"
	"testing"
	"time"
)

func TestParse(t *testing.T) {
	good := map[string]Semver{"1.2.3": {1, 2, 3}, "v0.4.0": {0, 4, 0}, "0.4.1+3.gabc1234": {0, 4, 1}, " 2.0.10 ": {2, 0, 10}}
	for in, want := range good {
		if got, ok := Parse(in); !ok || got != want {
			t.Errorf("Parse(%q) = %v %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "-1.2.3", "1..3", "<semver>"} {
		if _, ok := Parse(in); ok {
			t.Errorf("Parse(%q) should fail", in)
		}
	}
}

// The same cases the Mac daemon's CompatTests use: while MAJOR is 0 the MINOR must match; from 1.0.0 the MAJOR must match.
func TestJudge(t *testing.T) {
	cases := []struct {
		peer, me, min string
		want          Verdict
	}{
		{"0.4.0", "0.4.0", "0.2.0", Compatible},
		{"0.4.9", "0.4.0", "0.2.0", Compatible},
		{"0.3.0", "0.4.0", "0.2.0", PeerTooOld},
		{"0.5.0", "0.4.0", "0.2.0", PeerTooNew},
		{"0.1.0", "0.2.0", "0.2.0", PeerTooOld},
		{"1.2.0", "1.0.0", "0.2.0", Compatible},
		{"2.0.0", "1.9.0", "0.2.0", PeerTooNew},
		{"1.0.0", "2.0.0", "0.2.0", PeerTooOld},
		{"0.4.0", "0.4.0", "0.4.1", PeerTooOld},
		{"junk", "0.4.0", "0.2.0", PeerUnreadable},
		{"0.4.0", "junk", "0.2.0", PeerUnreadable},
	}
	for _, c := range cases {
		if got := Judge(c.peer, c.me, c.min); got != c.want {
			t.Errorf("Judge(%s,%s,%s) = %v want %v", c.peer, c.me, c.min, got, c.want)
		}
	}
}

func TestEvaluate(t *testing.T) {
	now := time.Date(2027, 1, 15, 8, 10, 0, 0, time.UTC)
	if got := Evaluate(nil, "0.4.0", "0.2.0", now); !got.OK || !strings.HasPrefix(got.Message, "no app has connected") {
		t.Errorf("no app seen must be a note: %+v", got)
	}
	seen := []Sighting{{"0.3.0", now.Add(-time.Hour)}, {"0.4.0", now.Add(-2 * time.Minute)}}
	if got := Evaluate(seen, "0.4.0", "0.2.0", now); !got.OK || !strings.Contains(got.Message, "0.4.0, 2 minutes ago") {
		t.Errorf("newest app is compatible: %+v", got)
	}
	got := Evaluate([]Sighting{{"0.3.0", now}}, "0.4.0", "0.2.0", now)
	if got.OK || got.Fix == "" {
		t.Errorf("an old app is a warning with a fix: %+v", got)
	}
	if got := Evaluate([]Sighting{{"0.5.0", now}}, "0.4.0", "0.2.0", now); got.OK || !strings.Contains(got.Fix, "Update the daemon") {
		t.Errorf("a newer app says update the daemon: %+v", got)
	}
}

func TestAgeText(t *testing.T) {
	now := time.Now()
	for d, want := range map[time.Duration]string{0: "0 seconds ago", 80 * time.Second: "80 seconds ago", 10 * time.Minute: "10 minutes ago", 5 * time.Hour: "5 hours ago", 72 * time.Hour: "3 days ago"} {
		if got := AgeText(now.Add(-d), now); got != want {
			t.Errorf("%v: %q want %q", d, got, want)
		}
	}
}
