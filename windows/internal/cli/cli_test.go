package cli

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"greenfield-inserter/internal/compat"
	"greenfield-inserter/internal/health"
	"greenfield-inserter/internal/selftest"
	"greenfield-inserter/internal/state"
)

type harness struct {
	out, err bytes.Buffer
	d        Deps
	dir      string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	h := &harness{dir: t.TempDir()}
	env := map[string]string{}
	h.d = Deps{
		Out: &h.out, Err: &h.err, Getenv: func(k string) string { return env[k] }, Cwd: h.dir, OS: "windows",
		Paths: state.Paths{Dir: filepath.Join(h.dir, "state")}, Now: func() time.Time { return time.Date(2027, 1, 15, 8, 0, 0, 0, time.UTC) },
		Health: func(int) health.Outcome { return health.Outcome{Snapshot: healthySnapshot()} },
		HostInfo: func(int) health.Host {
			return health.Host{TailscaleTool: "tailscale.exe", FirewallKnown: true, FirewallRule: true, OS: "windows"}
		},
		StatusJSON: func() []byte {
			return []byte(`{"Self":{"HostName":"pc","DNSName":"pc.tail1234.ts.net.","TailscaleIPs":["100.64.0.10"],"OS":"windows","Online":true,"UserID":1},"Peer":{}}`)
		},
		Elevated: func() bool { return true }, FocusWait: 50 * time.Millisecond,
	}
	return h
}

func (h *harness) run(args ...string) int { return Main(args, h.d) }

func healthySnapshot() *health.Snapshot {
	at := time.Now().Add(-time.Minute)
	return &health.Snapshot{Name: "PC", Version: "0.4.0", Listen: []string{"100.64.0.10:47821", "127.0.0.1:47821"}, InputAllowed: true, Auth: "tailnet", IdentityOK: true,
		LogsAvailable: true, CanInsert: state.CanInsert{State: state.StateOK, At: &at, Source: "selftest"}, AppCompatible: &compat.AppCompat{OK: true, Message: "no app has connected yet"}}
}

func TestHelpVersionAndUnknownCommand(t *testing.T) {
	h := newHarness(t)
	if h.run("help") != 0 || !strings.Contains(h.out.String(), "serve [--port N]") {
		t.Errorf("help: %s", h.out.String())
	}
	for _, name := range []string{"serve", "health", "doctor", "ready", "selftest", "link", "firewall", "pair", "logs", "name", "port", "version"} {
		if !strings.Contains(h.out.String(), name) {
			t.Errorf("help does not mention %s", name)
		}
	}
	h.out.Reset()
	if h.run("version") != 0 || !strings.HasPrefix(h.out.String(), "greenfield-inserter ") {
		t.Errorf("version: %s", h.out.String())
	}
	h.out.Reset()
	if code := h.run("frobnicate"); code != 2 || !strings.Contains(h.err.String(), "unknown command") {
		t.Errorf("unknown: %d %s", code, h.err.String())
	}
	for _, c := range []string{"assist", "permissions"} {
		h.out.Reset()
		if h.run(c) != 0 || !strings.Contains(h.out.String(), "Windows") {
			t.Errorf("%s: %s", c, h.out.String())
		}
	}
}

func TestPortComesFromFlagThenEnvironmentThenDotEnvThenDefault(t *testing.T) {
	h := newHarness(t)
	get := func(args ...string) string {
		h.out.Reset()
		h.run(append([]string{"port"}, args...)...)
		return strings.TrimSpace(h.out.String())
	}
	if got := get(); got != "47821" {
		t.Errorf("default %s", got)
	}
	os.WriteFile(filepath.Join(h.dir, ".env"), []byte("GREENFIELD_PORT=6000\n"), 0o600)
	if got := get(); got != "6000" {
		t.Errorf(".env %s", got)
	}
	h.d.Getenv = func(k string) string {
		if k == "GREENFIELD_PORT" {
			return "5000"
		}
		return ""
	}
	if got := get(); got != "5000" {
		t.Errorf("env %s", got)
	}
	if got := get("--port", "4000"); got != "4000" {
		t.Errorf("flag %s", got)
	}
	if got := get("--port=4001"); got != "4001" {
		t.Errorf("flag= %s", got)
	}
	h.err.Reset()
	if code := h.run("port", "--port", "nope"); code != 2 || !strings.Contains(h.err.String(), "bad port") {
		t.Errorf("%d %s", code, h.err.String())
	}
	if code := h.run("port", "--port"); code != 2 {
		t.Errorf("a flag without a value: %d", code)
	}
}

func TestServePassesTheOptionsOn(t *testing.T) {
	h := newHarness(t)
	var got ServeOptions
	h.d.Serve = func(_ context.Context, o ServeOptions) error { got = o; return nil }
	if code := h.run("serve", "--port", "5555", "--bind", "127.0.0.1", "--name", "Desk", "--log-stderr", "--no-bonjour", "--no-admin-check", "--dry-run"); code != 0 {
		t.Fatalf("%d %s", code, h.err.String())
	}
	if got.Port != 5555 || got.Bind != "127.0.0.1" || got.Name != "Desk" || !got.LogStderr || !got.NoBonjour || !got.NoAdminCheck || !got.DryRun || got.Paths.Dir != h.d.Paths.Dir {
		t.Errorf("%+v", got)
	}
	got = ServeOptions{}
	if h.run() != 0 || got.Port != 47821 {
		t.Errorf("serve is the default command: %+v", got)
	}
	h.d.Serve = func(context.Context, ServeOptions) error { return errors.New("port busy") }
	if code := h.run("serve"); code != 1 || !strings.Contains(h.err.String(), "port busy") {
		t.Errorf("%d %s", code, h.err.String())
	}
}

func TestHealthAndReady(t *testing.T) {
	h := newHarness(t)
	if code := h.run("health"); code != 0 || !strings.Contains(h.out.String(), "Healthy.") {
		t.Errorf("%d\n%s", code, h.out.String())
	}
	h.out.Reset()
	if code := h.run("ready"); code != 0 || strings.TrimSpace(h.out.String()) != "ready" {
		t.Errorf("%d %q", code, h.out.String())
	}
	h.d.Health = func(int) health.Outcome { return health.Outcome{Unreachable: "connection refused"} }
	h.out.Reset()
	if code := h.run("health"); code != 1 || !strings.Contains(h.out.String(), "doctor") || strings.Contains(h.out.String(), "fix:") {
		t.Errorf("%d\n%s", code, h.out.String())
	}
	h.out.Reset()
	if code := h.run("ready"); code != 1 || !strings.Contains(h.out.String(), "Next step:") || !strings.Contains(h.out.String(), "serve") {
		t.Errorf("%d %q", code, h.out.String())
	}
}

func TestDoctorShowsWhyAndFixAndRunsTheLiveTestWhenOnlyProofIsMissing(t *testing.T) {
	h := newHarness(t)
	// A problem that is not about proof: no live test, exit 1, with why and fix.
	s := healthySnapshot()
	s.ScreenLocked = true
	h.d.Health = func(int) health.Outcome { return health.Outcome{Snapshot: s} }
	if code := h.run("doctor"); code != 1 || !strings.Contains(h.out.String(), "why:") || !strings.Contains(h.out.String(), "fix: Unlock this computer.") || strings.Contains(h.out.String(), "live test") {
		t.Errorf("%d\n%s", code, h.out.String())
	}
	// Only the proof is missing: the live test runs (here against a fake window and a fake daemon via the field/Post seams).
	h.out.Reset()
	s = healthySnapshot()
	s.CanInsert = state.CanInsert{State: state.StateUnknown, Detail: "none yet"}
	h.d.Health = func(int) health.Outcome { return health.Outcome{Snapshot: s} }
	h.d.SelfField = func() selftest.Field { return &stuckField{} }
	code := h.run("doctor")
	if !strings.Contains(h.out.String(), "running the live test") || !strings.Contains(h.out.String(), "FAIL at step \"focus\"") || code != 1 {
		t.Errorf("%d\n%s", code, h.out.String())
	}
	h.out.Reset()
	if code := h.run("doctor", "--no-selftest"); code != 1 || strings.Contains(h.out.String(), "live test") {
		t.Errorf("--no-selftest: %d\n%s", code, h.out.String())
	}
	// All good.
	h.out.Reset()
	h.d.Health = func(int) health.Outcome { return health.Outcome{Snapshot: healthySnapshot()} }
	if code := h.run("doctor"); code != 0 || !strings.Contains(h.out.String(), "All good.") {
		t.Errorf("%d\n%s", code, h.out.String())
	}
}

type stuckField struct{}

func (*stuckField) Open() error          { return nil }
func (*stuckField) Focused() bool        { return false }
func (*stuckField) Text() (string, bool) { return "", false }
func (*stuckField) Close()               {}

func TestSelftestStopsAtPreflightWhenTheDaemonIsDown(t *testing.T) {
	h := newHarness(t)
	h.d.Health = func(int) health.Outcome { return health.Outcome{Unreachable: "refused"} }
	if code := h.run("selftest"); code != 1 || !strings.Contains(h.out.String(), `FAIL at step "preflight"`) {
		t.Errorf("%d\n%s", code, h.out.String())
	}
	if _, err := os.Stat(h.d.Paths.DeliveryFile()); err == nil {
		t.Errorf("a setup problem leaves no delivery evidence behind")
	}
}

func TestNameSetAndReset(t *testing.T) {
	h := newHarness(t)
	if h.run("name", "set", "Studio", "PC") != 0 || strings.TrimSpace(h.out.String()) != "Studio PC" {
		t.Errorf("%q", h.out.String())
	}
	h.out.Reset()
	if h.run("name") != 0 || strings.TrimSpace(h.out.String()) != "Studio PC" {
		t.Errorf("%q", h.out.String())
	}
	h.out.Reset()
	if h.run("name", "reset") != 0 || strings.TrimSpace(h.out.String()) == "Studio PC" {
		t.Errorf("reset: %q", h.out.String())
	}
	if h.run("name", "bogus") != 2 {
		t.Errorf("usage")
	}
}

func TestLinkUsesTheMagicDNSNameAndTheChosenName(t *testing.T) {
	h := newHarness(t)
	h.run("name", "set", "Desk PC")
	h.out.Reset()
	if code := h.run("link"); code != 0 || !strings.Contains(h.out.String(), "greenfield://add?name=Desk%20PC&address=pc.tail1234.ts.net") {
		t.Errorf("%d\n%s", code, h.out.String())
	}
	h.d.StatusJSON = func() []byte { return nil }
	if code := h.run("link"); code != 1 || !strings.Contains(h.err.String(), "Tailscale") {
		t.Errorf("%d %s", code, h.err.String())
	}
}

func TestFirewallShowsAddsAndRemoves(t *testing.T) {
	h := newHarness(t)
	if h.run("firewall") != 0 || !strings.Contains(h.out.String(), `netsh advfirewall firewall add rule name="Greenfield inserter (TCP 47821)"`) || !strings.Contains(h.out.String(), "remoteip=100.64.0.0/10") {
		t.Errorf("%s", h.out.String())
	}
	var added, removed []int
	h.d.AddRule = func(p int) (string, error) { added = append(added, p); return "Ok.\n", nil }
	h.d.DeleteRule = func(p int) (string, error) { removed = append(removed, p); return "Deleted 1 rule(s).\n", nil }
	if h.run("firewall", "add", "--port", "5000") != 0 || len(added) != 1 || added[0] != 5000 {
		t.Errorf("add: %v", added)
	}
	if h.run("firewall", "remove") != 0 || len(removed) != 1 || removed[0] != 47821 {
		t.Errorf("remove: %v", removed)
	}
	h.d.Elevated = func() bool { return false }
	h.err.Reset()
	if code := h.run("firewall", "add"); code != 1 || !strings.Contains(h.err.String(), "administrator") || len(added) != 1 {
		t.Errorf("not elevated must not try: %d %s", code, h.err.String())
	}
	h.d.Elevated = func() bool { return true }
	h.d.AddRule = func(int) (string, error) { return "", errors.New("Access is denied") }
	if code := h.run("firewall", "add"); code != 1 {
		t.Errorf("a netsh failure: %d", code)
	}
	if h.run("firewall", "nope") != 2 {
		t.Errorf("usage")
	}
}

func TestLogsPrintsTheRedactedLogEvenWithTheDaemonStopped(t *testing.T) {
	h := newHarness(t)
	if code := h.run("logs"); code != 1 || !strings.Contains(h.err.String(), "no log yet") {
		t.Errorf("%d %s", code, h.err.String())
	}
	os.MkdirAll(h.d.Paths.Dir, 0o700)
	stamp := func(d time.Duration) string { return h.d.Now().Add(-d).Format(time.RFC3339) }
	os.WriteFile(h.d.Paths.LogFile(), []byte(stamp(2*time.Hour)+" old line\n"+stamp(time.Minute)+" new line key=abc123\n"+stamp(time.Second)+" last line\n"), 0o600)
	h.out.Reset()
	if code := h.run("logs", "--tail", "2"); code != 0 {
		t.Fatalf("%d", code)
	}
	if out := h.out.String(); strings.Contains(out, "old line") || strings.Contains(out, "abc123") || !strings.Contains(out, "key=<redacted>") || !strings.Contains(out, "last line") {
		t.Errorf("%s", out)
	}
	h.out.Reset()
	h.run("logs", "--since", "30m")
	if strings.Contains(h.out.String(), "old line") || !strings.Contains(h.out.String(), "new line") {
		t.Errorf("%s", h.out.String())
	}
	if h.run("logs", "--tail", "0") != 2 {
		t.Errorf("bad tail")
	}
}
