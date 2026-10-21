package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStandardPathsHonourTheOverride(t *testing.T) {
	t.Setenv("GREENFIELD_INSERTER_HOME", "/tmp/gf-test-home")
	p := Standard()
	if p.Dir != "/tmp/gf-test-home" || p.LogFile() != filepath.Join("/tmp/gf-test-home", "inserter.log") {
		t.Errorf("%+v", p)
	}
	t.Setenv("GREENFIELD_INSERTER_HOME", "")
	if d := Standard().Dir; !strings.HasSuffix(d, "greenfield-inserter") {
		t.Errorf("default dir %q", d)
	}
}

func TestClientLedgerKeepsFiveDistinctVersionsNewestFirst(t *testing.T) {
	now := time.Date(2027, 1, 1, 8, 0, 0, 0, time.UTC)
	c := &ClientLedger{File: filepath.Join(t.TempDir(), "sub", "clients.json"), Now: func() time.Time { return now }}
	if len(c.Recent()) != 0 {
		t.Fatal("empty at first")
	}
	for i, v := range []string{"0.4.0", "0.4.1", "0.4.0", "0.4.2", "0.4.3", "0.4.4", "0.4.5"} {
		now = now.Add(time.Minute * time.Duration(i+1))
		c.Saw(v)
	}
	got := c.Recent()
	var versions []string
	for _, s := range got {
		versions = append(versions, s.Version)
	}
	if strings.Join(versions, ",") != "0.4.5,0.4.4,0.4.3,0.4.2,0.4.0" {
		t.Errorf("got %v", versions)
	}
	c.Saw(strings.Repeat("9", 100))
	if v := c.Recent()[0].Version; len(v) != 40 {
		t.Errorf("a version is cut to 40 characters, got %d", len(v))
	}
	// Another process (health) reading the same file sees the same thing.
	other := &ClientLedger{File: c.File}
	if len(other.Recent()) != 5 {
		t.Errorf("shared file")
	}
	if err := os.WriteFile(c.File, []byte("garbage"), 0o600); err != nil {
		t.Fatal(err)
	}
	if len(c.Recent()) != 0 {
		t.Errorf("a damaged file reads as empty")
	}
}

func TestDeliveryLedgerEvidenceRules(t *testing.T) {
	start := time.Date(2027, 1, 1, 8, 0, 0, 0, time.UTC)
	now := start
	l := &DeliveryLedger{File: filepath.Join(t.TempDir(), "delivery.json"), DaemonStart: start, Now: func() time.Time { return now }}
	if c := l.CanInsert(); c.State != StateUnknown || c.At != nil {
		t.Fatalf("nothing yet: %+v", c)
	}
	now = start.Add(time.Minute)
	l.RecordSuccess("selftest")
	if c := l.CanInsert(); c.State != StateOK || c.Source != "selftest" || c.At == nil {
		t.Fatalf("success: %+v", c)
	}
	now = start.Add(2 * time.Minute)
	l.RecordFailure("delivery", "the focused field did not change")
	if c := l.CanInsert(); c.State != StateFailed || c.Detail != "the focused field did not change" {
		t.Fatalf("a newer failure wins: %+v", c)
	}
	now = start.Add(3 * time.Minute)
	l.RecordSuccess("delivery")
	if c := l.CanInsert(); c.State != StateOK {
		t.Fatalf("a newer success wins: %+v", c)
	}
	// Evidence older than a week, or older than the daemon, does not count.
	now = start.Add(8 * 24 * time.Hour)
	if c := l.CanInsert(); c.State != StateUnknown {
		t.Fatalf("expired: %+v", c)
	}
	now = start.Add(time.Minute)
	restarted := &DeliveryLedger{File: l.File, DaemonStart: start.Add(10 * time.Minute), Now: func() time.Time { return start.Add(11 * time.Minute) }}
	if c := restarted.CanInsert(); c.State != StateUnknown {
		t.Fatalf("evidence from before the daemon started: %+v", c)
	}
	j := (CanInsert{State: StateOK, Source: "selftest", Detail: "d", At: &start}).JSON()
	if j["state"] != "ok" || j["source"] != "selftest" || j["at"] != "2027-01-01T08:00:00Z" {
		t.Errorf("json %v", j)
	}
	if _, has := (CanInsert{State: StateUnknown}).JSON()["at"]; has {
		t.Errorf("no time without evidence")
	}
	if _, err := json.Marshal(j); err != nil {
		t.Error(err)
	}
}

func TestDedupe(t *testing.T) {
	now := time.Now()
	d := NewDedupe()
	d.Now = func() time.Time { return now }
	if _, ok := d.Lookup("a"); ok {
		t.Fatal("empty")
	}
	d.Remember("a", Response{200, []byte("x")})
	if r, ok := d.Lookup("a"); !ok || r.Status != 200 || string(r.Body) != "x" {
		t.Fatal("remembered")
	}
	now = now.Add(16 * time.Minute)
	if _, ok := d.Lookup("a"); ok {
		t.Fatal("expires after 15 minutes")
	}
	d.Capacity = 3
	for _, id := range []string{"1", "2", "3", "4"} {
		d.Remember(id, Response{Status: 200})
	}
	if _, ok := d.Lookup("1"); ok {
		t.Error("the oldest id is dropped past the capacity")
	}
	if _, ok := d.Lookup("4"); !ok {
		t.Error("the newest stays")
	}
}

func TestNameStore(t *testing.T) {
	n := NameStore{File: filepath.Join(t.TempDir(), "name"), Hostname: func() (string, error) { return "DESKTOP-1", nil }}
	if n.Current() != "DESKTOP-1" {
		t.Errorf("host name by default: %q", n.Current())
	}
	if err := n.Set("  Studio   PC \n"); err != nil || n.Current() != "Studio PC" {
		t.Errorf("set: %q %v", n.Current(), err)
	}
	if n.Set("   ") == nil {
		t.Error("an empty name is refused")
	}
	if err := n.Clear(); err != nil || n.Current() != "DESKTOP-1" {
		t.Errorf("clear: %q %v", n.Current(), err)
	}
	if err := n.Clear(); err != nil {
		t.Errorf("clearing twice: %v", err)
	}
	bad := NameStore{File: filepath.Join(t.TempDir(), "name"), Hostname: func() (string, error) { return "", errors.New("no") }}
	if bad.Current() != "Windows computer" {
		t.Errorf("fallback %q", bad.Current())
	}
}
