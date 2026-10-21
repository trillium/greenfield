package selftest

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"greenfield-inserter/internal/health"
	"greenfield-inserter/internal/inserter"
)

// fakeField stands in for the Win32 window: whatever the fake daemon "types" lands in text, with Return as the field's own CRLF.
type fakeField struct {
	mu                 sync.Mutex
	text               string
	openErr            error
	focusAfter         int // Focused() is true after this many asks (-1 = never)
	asks               int
	unreadable, closed bool
}

func (f *fakeField) Open() error { return f.openErr }
func (f *fakeField) Focused() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asks++
	return f.focusAfter >= 0 && f.asks > f.focusAfter
}
func (f *fakeField) Text() (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.text, !f.unreadable
}
func (f *fakeField) Close() { f.closed = true }
func (f *fakeField) type_(s string) {
	f.mu.Lock()
	f.text += strings.ReplaceAll(inserter.NormalizeNewlines(s), "\n", "\r\n")
	f.mu.Unlock()
}

type fakeDaemon struct {
	field  *fakeField
	status int
	body   map[string]any
	err    error
	typeIt bool
	posted []string
}

func (d *fakeDaemon) Post(id, text string) (int, map[string]any, error) {
	d.posted = append(d.posted, text)
	if d.err != nil {
		return 0, nil, d.err
	}
	if d.status == 200 && d.typeIt {
		d.field.type_(text)
	}
	return d.status, d.body, nil
}

type rec struct{ ok, bad []string }

func (r *rec) RecordSuccess(s string)    { r.ok = append(r.ok, s) }
func (r *rec) RecordFailure(s, d string) { r.bad = append(r.bad, s+": "+d) }

func uniq() func() string {
	n := 0
	return func() string { n++; return strconv.Itoa(n) }
}

func healthy() []health.Check {
	return []health.Check{{ID: "daemon", Status: health.Pass}, {ID: "auth", Status: health.Pass}, {ID: "can-insert", Status: health.Fail}, {ID: "input", Status: health.Fail}}
}

func TestPassRecordsEvidence(t *testing.T) {
	f := &fakeField{}
	d := &fakeDaemon{field: f, status: 200, body: map[string]any{"ok": true}, typeIt: true}
	r := &rec{}
	res := Run(healthy(), f, d, r, uniq(), time.Second)
	if !res.Pass || len(r.ok) != 1 || r.ok[0] != "selftest" || len(r.bad) != 0 || !f.closed {
		t.Fatalf("%+v\n%v", res, r)
	}
	if len(d.posted) != 2 || d.posted[0] != "greenfield selftest 1" || d.posted[1] != "line one\nline two" {
		t.Errorf("posted %q", d.posted)
	}
	if !strings.Contains(res.Text(), "PASS") {
		t.Error(res.Text())
	}
	// Not-blocking failures (the app in front, no evidence yet) did not stop it.
}

func TestFailuresNameTheStep(t *testing.T) {
	type tc struct {
		name   string
		checks []health.Check
		field  *fakeField
		daemon func(*fakeField) *fakeDaemon
		step   string
		inFix  string
	}
	cases := []tc{
		{"daemon down", []health.Check{{ID: "daemon", Title: "Daemon running", Status: health.Fail, Detail: "no answer", Fix: "serve it"}}, &fakeField{}, nil, "preflight", "serve it"},
		{"locked", []health.Check{{ID: "unlocked", Title: "Screen not locked", Status: health.Fail, Fix: "Unlock this computer."}}, &fakeField{}, nil, "preflight", "Unlock"},
		{"no window", healthy(), &fakeField{openErr: errors.New("no desktop")}, nil, "window", "desktop session"},
		{"no focus", healthy(), &fakeField{focusAfter: -1}, nil, "focus", "terminal"},
		{"daemon unreachable", healthy(), &fakeField{}, func(f *fakeField) *fakeDaemon { return &fakeDaemon{field: f, err: errors.New("refused")} }, "send", "health"},
		{"daemon refuses", healthy(), &fakeField{}, func(f *fakeField) *fakeDaemon {
			return &fakeDaemon{field: f, status: 503, body: map[string]any{"error": "accessibility_not_granted", "message": "admin"}}
		}, "send", "doctor"},
		{"keys never arrive", healthy(), &fakeField{}, func(f *fakeField) *fakeDaemon {
			return &fakeDaemon{field: f, status: 200, body: map[string]any{"ok": true}}
		}, "send", "administrator"},
		{"unreadable field", healthy(), &fakeField{unreadable: true}, func(f *fakeField) *fakeDaemon {
			return &fakeDaemon{field: f, status: 200, body: map[string]any{"ok": true}, typeIt: true}
		}, "send", "again"},
	}
	for _, c := range cases {
		if c.daemon == nil {
			c.daemon = func(f *fakeField) *fakeDaemon { return &fakeDaemon{field: f, status: 200, typeIt: true} }
		}
		r := &rec{}
		res := Run(c.checks, c.field, c.daemon(c.field), r, uniq(), 100*time.Millisecond)
		if res.Pass || res.Step != c.step || !strings.Contains(res.Fix, c.inFix) || res.Problem == "" {
			t.Errorf("%s: %+v", c.name, res)
		}
		if len(r.ok) != 0 {
			t.Errorf("%s: a failed test must not record success", c.name)
		}
		if c.step != "preflight" && len(r.bad) != 1 {
			t.Errorf("%s: a failed live step is recorded as evidence: %v", c.name, r.bad)
		}
		if c.step == "preflight" && len(r.bad) != 0 {
			t.Errorf("%s: a setup problem is not a delivery failure: %v", c.name, r.bad)
		}
		if !strings.Contains(res.Text(), "FAIL at step") {
			t.Errorf("%s: %s", c.name, res.Text())
		}
	}
}

func TestALineBreakThatArrivesAsNothingFails(t *testing.T) {
	f := &fakeField{}
	d := &fakeDaemon{field: f, status: 200, body: map[string]any{"ok": true}}
	calls := 0
	d2 := daemonFunc(func(id, text string) (int, map[string]any, error) {
		calls++
		if calls == 1 {
			f.type_(text)
		} else {
			f.type_(strings.ReplaceAll(text, "\n", "")) // the Return was lost
		}
		return 200, d.body, nil
	})
	res := Run(healthy(), f, d2, &rec{}, uniq(), time.Second)
	if res.Pass || res.Step != "line breaks" {
		t.Errorf("%+v", res)
	}
}

type daemonFunc func(id, text string) (int, map[string]any, error)

func (f daemonFunc) Post(id, text string) (int, map[string]any, error) { return f(id, text) }

func TestLoopbackPostsJSONToTheDaemon(t *testing.T) {
	var gotBody, gotType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, 500)
		n, _ := r.Body.Read(b)
		gotBody, gotType = string(b[:n]), r.Header.Get("Content-Type")
		if r.URL.Path != "/text" || r.Method != "POST" || r.Header.Get("X-Greenfield-App") != "" {
			w.WriteHeader(404)
			return
		}
		w.WriteHeader(200)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)
	port, _ := strconv.Atoi(u.Port())
	status, body, err := Loopback{Port: port, Timeout: time.Second}.Post("abc", "hi\nthere")
	if err != nil || status != 200 || body["ok"] != true {
		t.Fatalf("%d %v %v", status, body, err)
	}
	if gotType != "application/json" || !strings.Contains(gotBody, `"id":"abc"`) || !strings.Contains(gotBody, `"source":"selftest"`) || !strings.Contains(gotBody, `hi\nthere`) {
		t.Errorf("%s %s", gotType, gotBody)
	}
	if _, _, err := (Loopback{Port: 1, Timeout: 200 * time.Millisecond}).Post("a", "b"); err == nil {
		t.Error("closed port")
	}
}
