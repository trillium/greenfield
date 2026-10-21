package health

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"greenfield-inserter/internal/compat"
	"greenfield-inserter/internal/state"
)

func good() *Snapshot {
	now := time.Now().Add(-time.Minute)
	return &Snapshot{
		Name: "PC", Version: "0.4.0", Listen: []string{"100.64.0.10:47821", "127.0.0.1:47821"}, InputAllowed: true, Auth: "tailnet", IdentityOK: true,
		TailnetUser: "me@example.com", LogsAvailable: true, BuildCommit: "abc1234", PID: 99,
		CanInsert:     state.CanInsert{State: state.StateOK, At: &now, Source: "selftest"},
		AppCompatible: &compat.AppCompat{OK: true, Message: "no app has connected yet"},
	}
}

func byID(checks []Check, id string) Check {
	for _, c := range checks {
		if c.ID == id {
			return c
		}
	}
	return Check{ID: id, Title: "MISSING"}
}

func TestEverythingFineIsReady(t *testing.T) {
	checks := Checks(Outcome{Snapshot: good()}, 47821, nil)
	if Failed(checks) {
		t.Fatalf("\n%s", Render(checks, true))
	}
	if r := Ready(checks); !r.Ready || len(r.Notes) != 0 {
		t.Errorf("%+v", r)
	}
	if c := byID(checks, "app-compatible"); !strings.HasPrefix(c.Detail, "note:") || c.Status != Pass {
		t.Errorf("no app yet is a note: %+v", c)
	}
	if c := byID(checks, "auth"); !strings.Contains(c.Detail, "no key or password") {
		t.Errorf("%+v", c)
	}
}

func TestEachProblemNamesWhyAndFix(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Snapshot)
		id     string
	}{
		{"no tailnet address", func(s *Snapshot) { s.Listen = []string{"127.0.0.1:47821"} }, "tailnet"},
		{"listening on the LAN", func(s *Snapshot) { s.Listen = append(s.Listen, "192.168.1.5:47821") }, "listening"},
		{"identity unavailable", func(s *Snapshot) { s.IdentityOK = false }, "auth"},
		{"no auth field", func(s *Snapshot) { s.Auth = "" }, "auth"},
		{"input blocked", func(s *Snapshot) { s.InputAllowed = false }, "input"},
		{"locked", func(s *Snapshot) { s.ScreenLocked = true }, "unlocked"},
		{"password box", func(s *Snapshot) { s.SecureInput = true }, "secure-input"},
		{"no evidence", func(s *Snapshot) {
			s.CanInsert = state.CanInsert{State: state.StateUnknown, Detail: "no delivery has been confirmed"}
		}, "can-insert"},
		{"failed delivery", func(s *Snapshot) {
			s.CanInsert = state.CanInsert{State: state.StateFailed, Detail: "the focused field did not change"}
		}, "can-insert"},
	}
	for _, c := range cases {
		s := good()
		c.mutate(s)
		checks := Checks(Outcome{Snapshot: s}, 47821, nil)
		got := byID(checks, c.id)
		if got.Status != Fail || got.Why == "" || got.Fix == "" {
			t.Errorf("%s: %+v", c.name, got)
		}
		if !Failed(checks) {
			t.Errorf("%s: health must fail", c.name)
		}
	}
	s := good()
	s.Version = "0.0.0"
	s.LogsAvailable = false
	s.AppCompatible = &compat.AppCompat{OK: false, Message: "the newest app seen is older", Fix: "Update the app"}
	checks := Checks(Outcome{Snapshot: s}, 47821, nil)
	for _, id := range []string{"version", "logs", "app-compatible"} {
		if c := byID(checks, id); c.Status != Warn || c.Fix == "" {
			t.Errorf("%s should warn with a fix: %+v", id, c)
		}
	}
	if Failed(checks) {
		t.Errorf("warnings do not fail health")
	}
}

func TestUnreachableAndForeignDaemons(t *testing.T) {
	checks := Checks(Outcome{Unreachable: "connection refused"}, 47821, nil)
	if c := byID(checks, "daemon"); c.Status != Fail || !strings.Contains(c.Fix, "serve") || !strings.Contains(c.Detail, "47821") {
		t.Errorf("%+v", c)
	}
	skipped := 0
	for _, c := range checks {
		if c.Status == Skip {
			skipped++
		}
	}
	if skipped != 8 {
		t.Errorf("everything else is skipped, got %d", skipped)
	}
	checks = Checks(Outcome{HTTP: 404}, 47821, nil)
	if c := byID(checks, "daemon"); c.Status != Fail || !strings.Contains(c.Detail, "404") {
		t.Errorf("%+v", c)
	}
}

func TestHostChecks(t *testing.T) {
	win := func(h Host) []Check {
		h.OS = "windows"
		return Checks(Outcome{Snapshot: good()}, 47821, &h)
	}
	if c := byID(win(Host{}), "tailscale-cli"); c.Status != Fail || c.Fix == "" {
		t.Errorf("%+v", c)
	}
	if c := byID(win(Host{TailscaleTool: `C:\Program Files\Tailscale\tailscale.exe`, FirewallKnown: true}), "firewall"); c.Status != Fail || !strings.Contains(c.Fix, "firewall add") {
		t.Errorf("no rule: %+v", c)
	}
	if c := byID(win(Host{TailscaleTool: "x", FirewallKnown: true, FirewallRule: true}), "firewall"); c.Status != Pass {
		t.Errorf("rule present: %+v", c)
	}
	connected := good()
	connected.AppCompatible = &compat.AppCompat{OK: true, Message: "the newest app seen (0.4.0, 2 minutes ago) is compatible with daemon 0.4.0"}
	h := Host{TailscaleTool: "x", FirewallKnown: true, OS: "windows"}
	if c := byID(Checks(Outcome{Snapshot: connected}, 47821, &h), "firewall"); c.Status != Warn {
		t.Errorf("no rule but an app got through is only a warning: %+v", c)
	}
	if c := byID(win(Host{TailscaleTool: "x"}), "firewall"); c.Status != Warn {
		t.Errorf("firewall unreadable is a warning: %+v", c)
	}
	if c := byID(Checks(Outcome{Snapshot: good()}, 47821, &Host{TailscaleTool: "x", OS: "darwin"}), "firewall"); c.Title != "MISSING" {
		t.Errorf("no firewall check off Windows")
	}
}

func TestReadyGivesExactlyOneNextStepInOrder(t *testing.T) {
	s := good()
	s.CanInsert = state.CanInsert{State: state.StateUnknown, Detail: "none"}
	s.InputAllowed = false
	s.IdentityOK = false
	checks := Checks(Outcome{Snapshot: s}, 47821, &Host{TailscaleTool: "x", OS: "windows", FirewallKnown: true})
	r := Ready(checks)
	if r.Ready || !strings.Contains(r.Step, "Tailscale") {
		t.Fatalf("identity first: %+v", r)
	}
	s.IdentityOK = true
	if r = Ready(Checks(Outcome{Snapshot: s}, 47821, &Host{TailscaleTool: "x", OS: "windows", FirewallKnown: true})); !strings.Contains(r.Step, "firewall add") {
		t.Fatalf("then the firewall: %+v", r)
	}
	if r = Ready(Checks(Outcome{Snapshot: s}, 47821, &Host{TailscaleTool: "x", OS: "windows", FirewallKnown: true, FirewallRule: true})); !strings.Contains(r.Step, "Click into a normal app") {
		t.Fatalf("then input: %+v", r)
	}
	s.InputAllowed = true
	if r = Ready(Checks(Outcome{Snapshot: s}, 47821, nil)); !strings.Contains(r.Step, "selftest") {
		t.Fatalf("then proof: %+v", r)
	}
	// Locked and password-box are notes on a ready daemon, never the thing to do.
	s = good()
	s.ScreenLocked, s.SecureInput = true, true
	r = Ready(Checks(Outcome{Snapshot: s}, 47821, nil))
	if !r.Ready || len(r.Notes) != 2 {
		t.Errorf("%+v", r)
	}
	if r = Ready(Checks(Outcome{Unreachable: "refused"}, 47821, nil)); r.Ready || !strings.Contains(r.Step, "serve") {
		t.Errorf("not running: %+v", r)
	}
}

func TestRenderShowsWhyAndFixOnlyInDoctor(t *testing.T) {
	s := good()
	s.ScreenLocked = true
	checks := Checks(Outcome{Snapshot: s}, 47821, nil)
	plain, verbose := Render(checks, false), Render(checks, true)
	if strings.Contains(plain, "why:") || !strings.Contains(verbose, "why:") || !strings.Contains(verbose, "fix: Unlock this computer.") {
		t.Errorf("\n%s\n---\n%s", plain, verbose)
	}
	if !strings.Contains(plain, "✗ Screen not locked") || !strings.Contains(plain, "✓ Daemon running") {
		t.Errorf("%s", plain)
	}
}

func TestParseSnapshotAndFetch(t *testing.T) {
	body := `{"ok":true,"version":"0.4.0","name":"PC","listen":["127.0.0.1:1"],"accessibility":true,"screen_locked":false,"secure_input":false,"auth":"tailnet","identity_ok":true,
		"tailnet_user":"me@example.com","evidence":{"state":"ok","at":"2027-01-15T08:00:00Z","source":"selftest","detail":"d"},"min_client_version":"0.2.0",
		"app_compatible":{"ok":false,"message":"m","fix":"f"},"build":{"commit":"abc","binary_sha":"0123"},"executable":"C:\\x.exe","pid":7,"logs_available":true,"platform":"windows"}`
	s, ok := ParseSnapshot([]byte(body))
	if !ok || s.Version != "0.4.0" || s.PID != 7 || s.BuildCommit != "abc" || s.CanInsert.State != state.StateOK || s.CanInsert.At == nil || s.AppCompatible.Fix != "f" || !s.LogsAvailable {
		t.Fatalf("%+v %v", s, ok)
	}
	for _, bad := range []string{``, `{}`, `nope`, `{"ok":true}`} {
		if _, ok := ParseSnapshot([]byte(bad)); ok {
			t.Errorf("%q", bad)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.Write([]byte(body))
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	n, _ := strconv.Atoi(port)
	if o := Fetch(n, time.Second); o.Snapshot == nil || o.Snapshot.Name != "PC" {
		t.Errorf("%+v", o)
	}
	if o := Fetch(1, 200*time.Millisecond); o.Unreachable == "" {
		t.Errorf("closed port: %+v", o)
	}
	notDaemon := httptest.NewServer(http.NotFoundHandler())
	defer notDaemon.Close()
	_, port, _ = net.SplitHostPort(strings.TrimPrefix(notDaemon.URL, "http://"))
	n, _ = strconv.Atoi(port)
	if o := Fetch(n, time.Second); o.HTTP != 404 || o.Snapshot != nil {
		t.Errorf("%+v", o)
	}
}
