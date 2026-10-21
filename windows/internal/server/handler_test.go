package server

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"greenfield-inserter/internal/inserter"
	"greenfield-inserter/internal/logsvc"
	"greenfield-inserter/internal/state"
	"greenfield-inserter/internal/tailnet"
)

const (
	phoneAddr = "100.64.0.20"
	otherAddr = "100.64.0.30"
	deadAddr  = "100.64.0.99"
)

type fakeProbe struct {
	locked, secure bool
	blocked        string // non-empty: InputAllowed is false, with this reason
}

func (p *fakeProbe) SecureInput() bool  { return p.secure }
func (p *fakeProbe) ScreenLocked() bool { return p.locked }
func (p *fakeProbe) InputAllowed() (bool, string) {
	return p.blocked == "", p.blocked
}

type fakeInserter struct {
	mu      sync.Mutex
	texts   []string
	methods []inserter.Method
	outcome inserter.Outcome
	err     error
}

func (f *fakeInserter) Insert(text string, m inserter.Method) (inserter.Outcome, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return inserter.Outcome{}, f.err
	}
	f.texts = append(f.texts, text)
	f.methods = append(f.methods, m)
	return f.outcome, nil
}

type fakeIdentity struct{}

func (fakeIdentity) Identify(a string) tailnet.Peer {
	switch a {
	case phoneAddr:
		return tailnet.Peer{Kind: tailnet.SameUser, Login: "me@example.com"}
	case otherAddr:
		return tailnet.Peer{Kind: tailnet.OtherUser, Login: "them@example.com"}
	}
	return tailnet.Peer{Kind: tailnet.Unknown, Why: "tailscale could not identify " + a}
}
func (fakeIdentity) SelfLogin() string { return "me@example.com" }

type fakeDiscovery struct{}

func (fakeDiscovery) Computers() []tailnet.Computer {
	return []tailnet.Computer{{Name: "This PC", Address: "pc.tail1234.ts.net", Version: "0.4.0", Self: true}, {Name: "Studio Mac", Address: "studio.tail1234.ts.net", Version: "0.4.1"}}
}

type env struct {
	h     *Handler
	probe *fakeProbe
	ins   *fakeInserter
	log   *logBuf
	clock *time.Time
	dir   string
}

type logBuf struct {
	mu    sync.Mutex
	lines []string
}

func (l *logBuf) Log(m string) { l.mu.Lock(); l.lines = append(l.lines, m); l.mu.Unlock() }
func (l *logBuf) all() string  { l.mu.Lock(); defer l.mu.Unlock(); return strings.Join(l.lines, "\n") }

var epoch = time.Date(2027, 1, 15, 8, 0, 0, 0, time.UTC)

func newEnv(t *testing.T) *env {
	t.Helper()
	dir := t.TempDir()
	now := epoch
	e := &env{probe: &fakeProbe{}, ins: &fakeInserter{outcome: inserter.Outcome{Method: inserter.Type, Delivery: inserter.Unconfirmed}}, log: &logBuf{}, clock: &now, dir: dir}
	logFile := filepath.Join(dir, "inserter.log")
	lg := logsvc.NewLogger(logFile, nil)
	lg.Now = func() time.Time { return *e.clock }
	lg.Log("started")
	e.h = New(Config{
		Probe: e.probe, Inserter: e.ins, Identity: fakeIdentity{}, Discovery: fakeDiscovery{}, Logger: both{e.log, lg},
		Record:    &state.DeliveryLedger{File: filepath.Join(dir, "delivery.json"), DaemonStart: epoch, Now: func() time.Time { return *e.clock }},
		Clients:   &state.ClientLedger{File: filepath.Join(dir, "clients.json"), Now: func() time.Time { return *e.clock }},
		LogSource: logsvc.NewFileSource(logFile),
		Name:      func() string { return "Example PC" }, Listening: func() []string { return []string{"100.64.0.10:47821", "127.0.0.1:47821"} },
		Version: "0.4.0", MinClient: "0.2.0",
		Build:      Build{Version: "0.4.0", Commit: "abc1234", BinarySHA: "0123456789abcdef", StartedAt: "2027-01-15T08:00:00Z"},
		Executable: `C:\Users\me\greenfield-inserter.exe`,
		Now:        func() time.Time { return *e.clock },
	})
	return e
}

type both struct{ a, b Logger }

func (b both) Log(m string) { b.a.Log(m); b.b.Log(m) }

type reply struct {
	status int
	header http.Header
	body   map[string]any
	raw    string
}

func (e *env) do(from, method, path, body string, headers ...string) reply {
	var r *http.Request
	if body != "" {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	r.RemoteAddr = net.JoinHostPort(from, "50000")
	for i := 0; i+1 < len(headers); i += 2 {
		r.Header.Set(headers[i], headers[i+1])
	}
	w := httptest.NewRecorder()
	e.h.ServeHTTP(w, r)
	out := reply{status: w.Code, header: w.Header(), raw: w.Body.String()}
	_ = json.Unmarshal(w.Body.Bytes(), &out.body)
	return out
}

func (r reply) errorCode() string { s, _ := r.body["error"].(string); return s }

func text(id, t string) string {
	b, _ := json.Marshal(map[string]any{"id": id, "text": t, "source": "greenfield"})
	return string(b)
}

// --- authorization -----------------------------------------------------------------------------------------------------

func TestAuthorizationIsTailnetIdentity(t *testing.T) {
	e := newEnv(t)
	for _, c := range []struct {
		name, from string
		status     int
		code       string
	}{
		{"this computer", "127.0.0.1", 200, ""},
		{"same user's phone", phoneAddr, 200, ""},
		{"another user's device", otherAddr, 401, "unauthorized"},
		{"an address Tailscale cannot identify", deadAddr, 503, "identity_unavailable"},
	} {
		for _, path := range []string{"/status", "/peers"} {
			if r := e.do(c.from, "GET", path, ""); r.status != c.status || r.errorCode() != c.code {
				t.Errorf("%s %s: %d %q", c.name, path, r.status, r.errorCode())
			}
		}
	}
	// Refusals reveal nothing: an unauthorized caller gets the same answer whether or not the method is right.
	if r := e.do(otherAddr, "DELETE", "/text", ""); r.status != 401 {
		t.Errorf("method before authorization: %d", r.status)
	}
	if r := e.do(otherAddr, "POST", "/text", text("a", "hi")); r.status != 401 || len(e.ins.texts) != 0 {
		t.Errorf("unauthorized text must not be typed: %d %v", r.status, e.ins.texts)
	}
}

func TestAKeyNeverOpensTheDoor(t *testing.T) {
	e := newEnv(t)
	for _, from := range []string{otherAddr, deadAddr} {
		r := e.do(from, "POST", "/text", text("k", "hi"), "X-Dictation-Key", "anything")
		if r.status != 401 || r.errorCode() != "unauthorized" || len(e.ins.texts) != 0 {
			t.Errorf("%s: %d %q", from, r.status, r.errorCode())
		}
	}
	// A key sent by a caller that is authorized by identity is ignored, as on the Mac (the phone sends one only under Advanced).
	if r := e.do(phoneAddr, "GET", "/status", "", "X-Dictation-Key", "x"); r.status != 200 {
		t.Errorf("same-user caller with a key header: %d", r.status)
	}
}

func TestIdentityFailsClosedWithoutAnIdentitySource(t *testing.T) {
	e := newEnv(t)
	e.h.c.Identity = nil
	if r := e.do(phoneAddr, "GET", "/status", ""); r.status != 503 || r.errorCode() != "identity_unavailable" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if r := e.do("127.0.0.1", "GET", "/status", ""); r.status != 200 {
		t.Errorf("loopback needs no identity: %d", r.status)
	}
}

func TestLoopbackIsDecidedByTheSocketNotByHeaders(t *testing.T) {
	e := newEnv(t)
	if r := e.do(otherAddr, "GET", "/health", "", "X-Forwarded-For", "127.0.0.1", "Host", "127.0.0.1"); r.status != 403 || r.errorCode() != "local_only" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if r := e.do("::1", "GET", "/health", ""); r.status != 200 {
		t.Errorf("IPv6 loopback is this computer: %d", r.status)
	}
}

// --- routes ------------------------------------------------------------------------------------------------------------

func TestUnknownPathAndMethods(t *testing.T) {
	e := newEnv(t)
	if r := e.do(phoneAddr, "GET", "/nope", ""); r.status != 404 || r.errorCode() != "not_found" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if r := e.do(phoneAddr, "POST", "/status", "{}"); r.status != 405 || r.header.Get("Allow") != "GET" || r.errorCode() != "method_not_allowed" {
		t.Errorf("%d %q %q", r.status, r.errorCode(), r.header.Get("Allow"))
	}
	if r := e.do(phoneAddr, "GET", "/text", ""); r.status != 405 || r.header.Get("Allow") != "POST" {
		t.Errorf("%d %q", r.status, r.header.Get("Allow"))
	}
	if r := e.do("127.0.0.1", "POST", "/health", "{}"); r.status != 405 {
		t.Errorf("health is GET only: %d", r.status)
	}
	if r := e.do(phoneAddr, "GET", "/status", ""); r.header.Get("Content-Type") != "application/json" || r.header.Get("Cache-Control") != "no-store" || r.header.Get("Connection") != "close" {
		t.Errorf("headers %v", r.header)
	}
}

func TestStatusReportsWhatThePhoneReads(t *testing.T) {
	e := newEnv(t)
	r := e.do(phoneAddr, "GET", "/status", "")
	if r.status != 200 || r.body["ok"] != true {
		t.Fatalf("%d %v", r.status, r.body)
	}
	want := map[string]any{
		"service": "greenfield-inserter", "platform": "windows", "version": "0.4.0", "min_client_version": "0.2.0", "name": "Example PC",
		"auth": "tailnet", "key_configured": false, "tailnet_user": "me@example.com", "identity_ok": true,
		"accessibility": true, "accessibility_at_start": true, "screen_locked": false, "secure_input": false, "inserted_count": float64(0),
		"logs_available": true, "can_insert": false,
	}
	for k, v := range want {
		if r.body[k] != v {
			t.Errorf("%s = %v, want %v", k, r.body[k], v)
		}
	}
	if l, _ := r.body["listen"].([]any); len(l) != 2 {
		t.Errorf("listen %v", r.body["listen"])
	}
	assist, _ := r.body["assist"].(map[string]any)
	if assist["enabled"] != false || assist["windows"] != false || assist["pointer"] != false {
		t.Errorf("assist %v", assist)
	}
	if caps, ok := assist["capabilities"].([]any); !ok || len(caps) != 0 {
		t.Errorf("capabilities must be an empty list, got %v", assist["capabilities"])
	}
	d, _ := r.body["delivery"].(map[string]any)
	if d["ok"] != false || d["state"] != "unknown" || d["fix"] == "" || r.body["delivery_fix"] != d["fix"] || r.body["delivery_message"] != d["message"] {
		t.Errorf("delivery %v", d)
	}
	build, _ := r.body["build"].(map[string]any)
	if build["binary_sha"] != "0123456789abcdef" || build["commit"] != "abc1234" {
		t.Errorf("build %v", build)
	}
	logs, _ := r.body["logs"].(map[string]any)
	if logs["route"] != "/logs" || logs["max_lines"] != float64(2000) || logs["max_bytes"] != float64(262144) {
		t.Errorf("logs %v", logs)
	}
	// A status answer never contains text that was typed.
	e.do(phoneAddr, "POST", "/text", text("t1", "secret dictation words"))
	if r = e.do(phoneAddr, "GET", "/status", ""); strings.Contains(r.raw, "secret dictation") || r.body["inserted_count"] != float64(1) {
		t.Errorf("count %v", r.body["inserted_count"])
	}
}

func TestStatusReflectsTheComputer(t *testing.T) {
	e := newEnv(t)
	e.probe.locked, e.probe.secure, e.probe.blocked = true, true, "an app running as administrator has the focus"
	r := e.do(phoneAddr, "GET", "/status", "")
	if r.body["screen_locked"] != true || r.body["secure_input"] != true || r.body["accessibility"] != false {
		t.Errorf("%v", r.body)
	}
}

func TestHealthIsForThisComputerOnly(t *testing.T) {
	e := newEnv(t)
	r := e.do("127.0.0.1", "GET", "/health", "")
	if r.status != 200 || r.body["executable"] != `C:\Users\me\greenfield-inserter.exe` || r.body["pid"] == nil || r.body["version"] != "0.4.0" {
		t.Errorf("%d %v", r.status, r.body)
	}
	if r := e.do(phoneAddr, "GET", "/health", ""); r.status != 403 {
		t.Errorf("a phone is not this computer: %d", r.status)
	}
}

func TestPeers(t *testing.T) {
	e := newEnv(t)
	r := e.do(phoneAddr, "GET", "/peers", "")
	peers, _ := r.body["peers"].([]any)
	if r.status != 200 || r.body["ok"] != true || len(peers) != 2 {
		t.Fatalf("%d %v", r.status, r.body)
	}
	first := peers[0].(map[string]any)
	if first["name"] != "This PC" || first["address"] != "pc.tail1234.ts.net" || first["version"] != "0.4.0" || first["self"] != true {
		t.Errorf("%v", first)
	}
	e.h.c.Discovery = nil
	if r = e.do(phoneAddr, "GET", "/peers", ""); r.status != 200 || r.raw != `{"ok":true,"peers":[]}` {
		t.Errorf("no discovery is an empty list: %s", r.raw)
	}
}

// --- assist routes: answered cleanly as "not supported", never implemented ------------------------------------------------

func TestAssistRoutesAreNotSupportedHere(t *testing.T) {
	e := newEnv(t)
	for path, method := range map[string]string{"/assist/windows": "GET", "/assist/windows/focus": "POST", "/assist/pointer/session": "POST"} {
		r := e.do(phoneAddr, method, path, "{}")
		if r.status != 404 || r.errorCode() != "assist_off" || !strings.Contains(r.body["message"].(string), "not supported") {
			t.Errorf("%s: %d %q %v", path, r.status, r.errorCode(), r.body["message"])
		}
		// the wrong method is answered the same way: there is no tool to be wrong about
		if r := e.do(phoneAddr, "DELETE", path, ""); r.status != 404 {
			t.Errorf("%s DELETE: %d", path, r.status)
		}
		if r := e.do(otherAddr, method, path, "{}"); r.status != 401 {
			t.Errorf("%s from another user: %d", path, r.status)
		}
		if r := e.do(otherAddr, method, path, "{}", "X-Dictation-Key", "k"); r.status != 401 {
			t.Errorf("%s with a key: %d", path, r.status)
		}
	}
	// The version rule still applies before the answer, as on the Mac.
	if r := e.do(phoneAddr, "GET", "/assist/windows", "", "X-Greenfield-App", "0.1.0"); r.status != 426 {
		t.Errorf("version rule: %d", r.status)
	}
}

// --- version rule ------------------------------------------------------------------------------------------------------

func TestVersionRule(t *testing.T) {
	e := newEnv(t)
	cases := []struct {
		app  string
		want int
		code string
	}{
		{"0.4.0", 200, ""}, {"0.4.7", 200, ""}, {"0.3.0", 426, "app_too_old"}, {"0.1.0", 426, "app_too_old"}, {"0.5.0", 426, "app_too_new"}, {"banana", 426, "app_version_unreadable"},
	}
	for _, c := range cases {
		r := e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", c.app)
		if r.status != c.want || r.errorCode() != c.code {
			t.Errorf("%s: %d %q", c.app, r.status, r.errorCode())
		}
		if c.want == 426 {
			if r.header.Get("Upgrade") != "greenfield" || r.body["version"] != "0.4.0" || r.body["min_client_version"] != "0.2.0" || r.body["ok"] != false || r.body["message"] == "" {
				t.Errorf("%s: 426 body %v %v", c.app, r.header, r.body)
			}
		}
	}
	if r := e.do(phoneAddr, "POST", "/text", text("v1", "hi"), "X-Greenfield-App", "0.3.0"); r.status != 426 || len(e.ins.texts) != 0 {
		t.Errorf("an old app is refused before anything is typed: %d", r.status)
	}
	// No header (curl, the selftest) passes. The app's versions are remembered and judged in /status.
	if r := e.do(phoneAddr, "GET", "/status", ""); r.status != 200 {
		t.Errorf("no header: %d", r.status)
	}
	r := e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.4.2")
	compatLine, _ := r.body["app_compatible"].(map[string]any)
	clients, _ := r.body["clients"].([]any)
	if compatLine["ok"] != true || len(clients) < 2 || clients[0].(map[string]any)["version"] != "0.4.2" {
		t.Errorf("app_compatible %v clients %v", compatLine, clients)
	}
}

// --- POST /text ----------------------------------------------------------------------------------------------------------

func TestPostTextDeliversAndAnswers(t *testing.T) {
	e := newEnv(t)
	r := e.do(phoneAddr, "POST", "/text", text("6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E", "Hello, world."), "Content-Type", "application/json", "X-Greenfield-App", "0.4.0")
	if r.status != 200 || r.body["ok"] != true || r.body["id"] != "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E" || r.body["chars"] != float64(13) || r.body["method"] != "type" || r.body["delivery"] != "unconfirmed" {
		t.Fatalf("%d %v", r.status, r.body)
	}
	if len(e.ins.texts) != 1 || e.ins.texts[0] != "Hello, world." {
		t.Errorf("typed %v", e.ins.texts)
	}
	if _, has := r.body["duplicate"]; has {
		t.Errorf("a first delivery is not a duplicate")
	}
}

func TestLineBreaksAreKeptAsLineFeeds(t *testing.T) {
	e := newEnv(t)
	body := text("m1", "Dear team,\r\n\r\nThe build is green.\nThanks\r\n")
	if r := e.do(phoneAddr, "POST", "/text", body); r.status != 200 {
		t.Fatalf("%d", r.status)
	}
	if got := e.ins.texts[0]; got != "Dear team,\n\nThe build is green.\nThanks\n" {
		t.Errorf("the inserter gets one line ending, empty lines and the trailing newline kept: %q", got)
	}
}

func TestResendWithTheSameIDTypesNothingTwice(t *testing.T) {
	e := newEnv(t)
	first := e.do(phoneAddr, "POST", "/text", text("dup-1", "once"))
	again := e.do(phoneAddr, "POST", "/text", text("dup-1", "once"))
	if again.status != 200 || again.body["duplicate"] != true || again.body["ok"] != true || again.body["id"] != first.body["id"] || len(e.ins.texts) != 1 {
		t.Fatalf("%d %v typed=%v", again.status, again.body, e.ins.texts)
	}
	if r := e.do(phoneAddr, "POST", "/text", text("dup-2", "once")); r.status != 200 || len(e.ins.texts) != 2 {
		t.Errorf("a new id types again")
	}
	// X-Request-Id is accepted when the body has no id.
	r := e.do(phoneAddr, "POST", "/text", `{"text":"via header"}`, "X-Request-Id", "hdr-1")
	if r.status != 200 || r.body["id"] != "hdr-1" {
		t.Errorf("%d %v", r.status, r.body)
	}
}

func TestRefusedTextCanBeRetriedWithTheSameID(t *testing.T) {
	e := newEnv(t)
	e.probe.locked = true
	if r := e.do(phoneAddr, "POST", "/text", text("retry-1", "later")); r.status != 423 || r.errorCode() != "screen_locked" {
		t.Fatalf("%d %q", r.status, r.errorCode())
	}
	e.probe.locked = false
	if r := e.do(phoneAddr, "POST", "/text", text("retry-1", "later")); r.status != 200 || r.body["duplicate"] != nil || len(e.ins.texts) != 1 {
		t.Errorf("only successes are remembered: %d %v", r.status, r.body)
	}
}

func TestPostTextRefusals(t *testing.T) {
	e := newEnv(t)
	for _, c := range []struct {
		name   string
		mutate func()
		status int
		code   string
	}{
		{"locked screen", func() { e.probe.locked = true }, 423, "screen_locked"},
		{"password field", func() { e.probe.secure = true }, 409, "secure_input"},
		{"input not allowed", func() { e.probe.blocked = "an app running as administrator has the focus" }, 503, "accessibility_not_granted"},
	} {
		e.probe.locked, e.probe.secure, e.probe.blocked = false, false, ""
		c.mutate()
		r := e.do(phoneAddr, "POST", "/text", text("refusal-"+c.code, "x"))
		if r.status != c.status || r.errorCode() != c.code || r.body["ok"] != false || r.body["message"] == "" {
			t.Errorf("%s: %d %v", c.name, r.status, r.body)
		}
	}
	if len(e.ins.texts) != 0 {
		t.Errorf("nothing may be typed when refused: %v", e.ins.texts)
	}
	// Locked wins over secure input, which wins over the permission, as on the Mac.
	e.probe.locked, e.probe.secure, e.probe.blocked = true, true, "x"
	if r := e.do(phoneAddr, "POST", "/text", text("order", "x")); r.status != 423 {
		t.Errorf("order: %d", r.status)
	}
	e.probe.locked = false
	if r := e.do(phoneAddr, "POST", "/text", text("order", "x")); r.status != 409 {
		t.Errorf("order: %d", r.status)
	}
}

func TestPostTextBadRequests(t *testing.T) {
	e := newEnv(t)
	long := strings.Repeat("x", MaxTextBytes+1)
	cases := []struct {
		name, body string
		status     int
		code       string
	}{
		{"not json", "hello", 400, "bad_request"},
		{"json but not an object", `["a"]`, 400, "bad_request"},
		{"null", `null`, 400, "bad_request"},
		{"no id", `{"text":"hi"}`, 400, "bad_request"},
		{"empty id", `{"id":"","text":"hi"}`, 400, "bad_request"},
		{"long id", `{"id":"` + strings.Repeat("a", 129) + `","text":"hi"}`, 400, "bad_request"},
		{"id is a number", `{"id":5,"text":"hi"}`, 400, "bad_request"},
		{"no text", `{"id":"a"}`, 400, "bad_request"},
		{"empty text", `{"id":"a","text":""}`, 400, "bad_request"},
		{"text is a number", `{"id":"a","text":5}`, 400, "bad_request"},
		{"bad method", `{"id":"a","text":"hi","method":"shout"}`, 400, "bad_request"},
		{"method is a number", `{"id":"a","text":"hi","method":1}`, 400, "bad_request"},
		{"too large", `{"id":"a","text":"` + long + `"}`, 413, "too_large"},
	}
	for _, c := range cases {
		if r := e.do(phoneAddr, "POST", "/text", c.body); r.status != c.status || r.errorCode() != c.code {
			t.Errorf("%s: %d %q", c.name, r.status, r.errorCode())
		}
	}
	atLimit := `{"id":"edge","text":"` + strings.Repeat("x", MaxTextBytes) + `"}`
	if r := e.do(phoneAddr, "POST", "/text", atLimit); r.status != 200 {
		t.Errorf("exactly 256 KiB is allowed: %d", r.status)
	}
	// A body past the parser limit is refused before it is read.
	r := httptest.NewRequest("POST", "/text", strings.NewReader(strings.Repeat("x", maxBodyBytes+10)))
	r.RemoteAddr = phoneAddr + ":1"
	w := httptest.NewRecorder()
	e.h.ServeHTTP(w, r)
	if w.Code != 413 {
		t.Errorf("huge body: %d", w.Code)
	}
	// Chunked bodies are not supported, as on the Mac.
	r = httptest.NewRequest("POST", "/text", strings.NewReader(text("c", "x")))
	r.TransferEncoding = []string{"chunked"}
	r.ContentLength = -1
	r.RemoteAddr = phoneAddr + ":1"
	w = httptest.NewRecorder()
	e.h.ServeHTTP(w, r)
	if w.Code != 501 {
		t.Errorf("chunked: %d", w.Code)
	}
}

func TestMethodPasteAndTypeAreBothAccepted(t *testing.T) {
	e := newEnv(t)
	for i, m := range []string{"paste", "type"} {
		b, _ := json.Marshal(map[string]any{"id": "m" + m, "text": "hi", "method": m})
		r := e.do(phoneAddr, "POST", "/text", string(b))
		if r.status != 200 || r.body["method"] != "type" || e.ins.methods[i] != inserter.Method(m) {
			t.Errorf("%s: %d %v %v", m, r.status, r.body, e.ins.methods)
		}
	}
}

func TestInsertFailures(t *testing.T) {
	e := newEnv(t)
	e.ins.err = inserter.ErrNotDelivered
	r := e.do(phoneAddr, "POST", "/text", text("nd", "x"))
	if r.status != 502 || r.errorCode() != "not_delivered" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if c := e.h.c.Record.CanInsert(); c.State != state.StateFailed {
		t.Errorf("a provable non-delivery is evidence: %+v", c)
	}
	e.ins.err = inserter.ErrBlocked
	if r = e.do(phoneAddr, "POST", "/text", text("bl", "x")); r.status != 503 || r.errorCode() != "accessibility_not_granted" || !strings.Contains(r.body["message"].(string), "administrator") {
		t.Errorf("%d %v", r.status, r.body)
	}
	e.ins.err = assertErr("boom: token=abc123")
	if r = e.do(phoneAddr, "POST", "/text", text("bad", "x")); r.status != 500 || r.errorCode() != "insert_failed" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if strings.Contains(e.log.all(), "abc123") {
		t.Errorf("error text in the log is redacted")
	}
	// Failures are not remembered as delivered.
	e.ins.err = nil
	if r = e.do(phoneAddr, "POST", "/text", text("bad", "x")); r.status != 200 || r.body["duplicate"] != nil {
		t.Errorf("%d %v", r.status, r.body)
	}
}

type assertErr string

func (a assertErr) Error() string { return string(a) }

func TestConfirmedDeliveryIsEvidence(t *testing.T) {
	e := newEnv(t)
	e.ins.outcome = inserter.Outcome{Method: inserter.Type, Delivery: inserter.Confirmed}
	*e.clock = epoch.Add(time.Minute)
	r := e.do(phoneAddr, "POST", "/text", text("ev", "hello"))
	if r.body["delivery"] != "confirmed" {
		t.Fatalf("%v", r.body)
	}
	s := e.do(phoneAddr, "GET", "/status", "")
	d, _ := s.body["delivery"].(map[string]any)
	if s.body["can_insert"] != true || d["ok"] != true || d["state"] != "ok" || d["source"] != "delivery" || s.body["delivery_fix"] != "" {
		t.Errorf("%v", s.body)
	}
	if !strings.Contains(s.body["delivery_message"].(string), "by a real delivery") {
		t.Errorf("%v", s.body["delivery_message"])
	}
}

// --- logs ----------------------------------------------------------------------------------------------------------------

func TestLogsRoute(t *testing.T) {
	e := newEnv(t)
	e.do(phoneAddr, "POST", "/text", text("log-1", "my private dictation"))
	r := e.do(phoneAddr, "GET", "/logs?tail=50", "")
	if r.status != 200 || r.body["ok"] != true || r.body["tail"] != float64(50) || r.body["since_s"] != nil || r.body["name"] != "Example PC" {
		t.Fatalf("%d %v", r.status, r.body)
	}
	lines, _ := r.body["lines"].([]any)
	if len(lines) == 0 || r.body["count"] != float64(len(lines)) {
		t.Fatalf("lines %v", lines)
	}
	if strings.Contains(r.raw, "private dictation") {
		t.Errorf("dictated text must never be in a log")
	}
	if !strings.Contains(r.raw, "text id=log-1 source=greenfield sent chars=20 method=type delivery=unconfirmed") {
		t.Errorf("the delivery is logged by id and count: %s", r.raw)
	}
	// An older app does not stop a person getting the log.
	if r := e.do(phoneAddr, "GET", "/logs", "", "X-Greenfield-App", "0.1.0"); r.status != 200 {
		t.Errorf("no app-version gate on logs: %d", r.status)
	}
	// Text format.
	r = e.do(phoneAddr, "GET", "/logs?format=text&since=1h", "")
	if r.status != 200 || !strings.HasPrefix(r.header.Get("Content-Type"), "text/plain") || r.header.Get("X-Logs-Truncated") == "" || !strings.Contains(r.raw, "started") {
		t.Errorf("%d %v %q", r.status, r.header, r.raw)
	}
	// Errors.
	if r := e.do(phoneAddr, "GET", "/logs?tail=0", ""); r.status != 400 || r.errorCode() != "bad_request" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if r := e.do(phoneAddr, "POST", "/logs", ""); r.status != 405 {
		t.Errorf("%d", r.status)
	}
	if r := e.do(otherAddr, "GET", "/logs", ""); r.status != 401 {
		t.Errorf("another user: %d", r.status)
	}
	if r := e.do(otherAddr, "GET", "/logs", "", "X-Dictation-Key", "k"); r.status != 401 {
		t.Errorf("a key does not open the logs: %d", r.status)
	}
}

func TestLogsNoLogAndRateLimit(t *testing.T) {
	e := newEnv(t)
	e.h.c.LogSource = logsvc.NewFileSource(filepath.Join(e.dir, "missing.log"))
	if r := e.do(phoneAddr, "GET", "/logs", ""); r.status != 404 || r.errorCode() != "no_log" {
		t.Errorf("%d %q", r.status, r.errorCode())
	}
	if r := e.do(phoneAddr, "GET", "/status", ""); r.body["logs_available"] != false {
		t.Errorf("logs_available %v", r.body["logs_available"])
	}
	e = newEnv(t)
	for i := 0; i < 6; i++ {
		if r := e.do(phoneAddr, "GET", "/logs", ""); r.status != 200 {
			t.Fatalf("request %d: %d", i, r.status)
		}
	}
	r := e.do(phoneAddr, "GET", "/logs", "")
	if r.status != 429 || r.errorCode() != "rate_limited" || r.header.Get("Retry-After") == "" {
		t.Errorf("%d %q %q", r.status, r.errorCode(), r.header.Get("Retry-After"))
	}
}

func TestRequestLogDoesNotCarryCallerText(t *testing.T) {
	e := newEnv(t)
	e.do(phoneAddr, "GET", "/some%20secret%20path%20words", "")
	e.do(phoneAddr, "POST", "/text", `{"id":"id with spaces and text","text":"hello","source":"Dictated Words Here"}`)
	all := e.log.all()
	if strings.Contains(all, "secret") || strings.Contains(all, "spaces and text") || strings.Contains(all, "Dictated") {
		t.Errorf("caller-controlled text reached the log:\n%s", all)
	}
	if !strings.Contains(all, "(unknown) -> 404") || !strings.Contains(all, "id=(invalid) source=other") {
		t.Errorf("log shape:\n%s", all)
	}
}

// A retry of the same id that arrives while the first is still being typed waits for it and is answered from memory; /status never
// waits for a long text to finish typing.
func TestConcurrentRetryTypesOnceAndStatusDoesNotWait(t *testing.T) {
	e := newEnv(t)
	started, release := make(chan struct{}), make(chan struct{})
	slow := &blockingInserter{started: started, release: release}
	e.h.c.Inserter = slow
	results := make(chan reply, 2)
	go func() { results <- e.do(phoneAddr, "POST", "/text", text("same-id", "slow text")) }()
	<-started
	go func() { results <- e.do(phoneAddr, "POST", "/text", text("same-id", "slow text")) }()
	statusDone := make(chan reply, 1)
	go func() { statusDone <- e.do(phoneAddr, "GET", "/status", "") }()
	select {
	case r := <-statusDone:
		if r.status != 200 {
			t.Errorf("status while typing: %d", r.status)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("/status waited for the text that is being typed")
	}
	close(release)
	a, b := <-results, <-results
	if a.status != 200 || b.status != 200 || slow.calls.Load() != 1 {
		t.Fatalf("typed %d times: %d %d", slow.calls.Load(), a.status, b.status)
	}
	if (a.body["duplicate"] == true) == (b.body["duplicate"] == true) {
		t.Errorf("exactly one of the two answers is the duplicate: %v %v", a.body, b.body)
	}
}

type blockingInserter struct {
	started, release chan struct{}
	calls            atomic.Int32
}

func (b *blockingInserter) Insert(string, inserter.Method) (inserter.Outcome, error) {
	if b.calls.Add(1) == 1 {
		close(b.started)
	}
	<-b.release
	return inserter.Outcome{Method: inserter.Type, Delivery: inserter.Unconfirmed}, nil
}
