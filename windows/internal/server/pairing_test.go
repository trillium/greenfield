package server

import (
	"strings"
	"testing"
	"time"

	"greenfield-inserter/internal/pairing"
)

// One-time pairing of a browser outside the tailnet (the PWA): the routes, and above all that nothing here weakens the
// tailnet-identity path. The book itself is tested in internal/pairing.

func pairedEnv(t *testing.T) *env {
	t.Helper()
	e := newEnv(t)
	now := epoch
	m := pairing.NewLimited(1000, time.Minute)
	m.Now = func() time.Time { return now }
	e.h.c.Pairing = m
	return e
}

// pairedToken asks for a code as the person at this computer and exchanges it as a browser would.
func pairedToken(t *testing.T, e *env, device string) string {
	t.Helper()
	code, _ := e.do("127.0.0.1", "POST", "/pair/code", "{}").body["code"].(string)
	r := e.do("127.0.0.1", "POST", "/pair", `{"code":"`+code+`","device":"`+device+`"}`, "X-Forwarded-For", "100.99.1.2")
	token, _ := r.body["token"].(string)
	if r.status != 200 || token == "" {
		t.Fatalf("pairing failed: %d %s", r.status, r.raw)
	}
	return token
}

func TestOnlyThePersonAtThisComputerAsksForACode(t *testing.T) {
	e := pairedEnv(t)
	if r := e.do("127.0.0.1", "POST", "/pair/code", "{}"); r.status != 200 || len(r.body["code"].(string)) != 9 {
		t.Fatalf("%d %s", r.status, r.raw)
	}
	// a device of the same tailnet user is not enough: the code is handed out at the computer
	for _, c := range [][2]string{{"POST", "/pair/code"}, {"GET", "/pair/devices"}} {
		if r := e.do(phoneAddr, c[0], c[1], "{}"); r.status != 403 || r.errorCode() != "local_only" {
			t.Errorf("%s %s: %d %q", c[0], c[1], r.status, r.errorCode())
		}
	}
	if r := e.do(phoneAddr, "POST", "/pair/revoke", `{"all":true}`); r.status != 401 {
		t.Errorf("revoke by a remote device: %d", r.status)
	}
}

func TestARequestThroughAProxyIsNotThePersonAtThisComputer(t *testing.T) {
	e := pairedEnv(t)
	for _, h := range []string{"X-Forwarded-For", "Tailscale-User-Login", "Forwarded", "X-Real-IP", "Tailscale-Funnel-Request"} {
		if r := e.do("127.0.0.1", "POST", "/pair/code", "{}", h, "1.2.3.4"); r.status != 403 || r.errorCode() != "local_only" {
			t.Errorf("%s: %d %q", h, r.status, r.errorCode())
		}
	}
	if r := e.do("127.0.0.1", "GET", "/pair/devices", "", "X-Forwarded-For", "1.2.3.4"); r.status != 403 {
		t.Errorf("devices through a proxy: %d", r.status)
	}
}

func TestTheCodeAndTheTokenAreNeverLogged(t *testing.T) {
	e := pairedEnv(t)
	code, _ := e.do("127.0.0.1", "POST", "/pair/code", "{}").body["code"].(string)
	token, _ := e.do("127.0.0.1", "POST", "/pair", `{"code":"`+code+`"}`).body["token"].(string)
	e.do("127.0.0.1", "POST", "/text", text("a", "hi"), "X-Greenfield-Token", token)
	e.do("127.0.0.1", "POST", "/pair", `{"code":"WRONG-CODE"}`)
	log := e.log.all()
	for _, secret := range []string{code, strings.ReplaceAll(code, "-", ""), token, "WRONG"} {
		if secret == "" || strings.Contains(log, secret) {
			t.Errorf("the log holds %q", secret)
		}
	}
	if !strings.Contains(log, "pair code issued") {
		t.Error("issuing a code should leave a line")
	}
}

func TestExchangeGivesATokenThatSendsText(t *testing.T) {
	e := pairedEnv(t)
	token := pairedToken(t, e, "Test browser")
	if r := e.do(deadAddr, "POST", "/text", text("a1", "hello\nworld"), "X-Greenfield-Token", token); r.status != 200 {
		t.Fatalf("%d %s", r.status, r.raw)
	}
	if len(e.ins.texts) != 1 || e.ins.texts[0] != "hello\nworld" {
		t.Errorf("typed %q", e.ins.texts)
	}
	if r := e.do(deadAddr, "GET", "/status", "", "X-Greenfield-Token", token); r.status != 200 {
		t.Errorf("status: %d", r.status)
	}
}

func TestWrongBadAndRepeatedCodesAreRefused(t *testing.T) {
	e := pairedEnv(t)
	if r := e.do(deadAddr, "POST", "/pair", `{"code":"AAAA-AAAA"}`); r.status != 401 || r.errorCode() != "pair_refused" {
		t.Errorf("no code was issued: %d %q", r.status, r.errorCode())
	}
	for _, body := range []string{"not json", `{"code":5}`, `{}`} {
		if r := e.do(deadAddr, "POST", "/pair", body); r.status != 400 {
			t.Errorf("%q: %d", body, r.status)
		}
	}
	if r := e.do(deadAddr, "GET", "/pair", ""); r.status != 405 {
		t.Errorf("GET /pair: %d", r.status)
	}
	code, _ := e.do("127.0.0.1", "POST", "/pair/code", "{}").body["code"].(string)
	if r := e.do(deadAddr, "POST", "/pair", `{"code":"`+code+`"}`); r.status != 200 {
		t.Fatalf("%d", r.status)
	}
	if r := e.do(deadAddr, "POST", "/pair", `{"code":"`+code+`"}`); r.status != 401 {
		t.Errorf("a code is single use: %d", r.status)
	}
}

func TestExchangeIsRateLimited(t *testing.T) {
	e := newEnv(t)
	last := 0
	for i := 0; i < 12; i++ {
		last = e.do(deadAddr, "POST", "/pair", `{"code":"AAAA-AAAA"}`).status
	}
	if last != 429 {
		t.Errorf("12th attempt: %d", last)
	}
}

func TestATokenReachesStatusAndTextOnly(t *testing.T) {
	e := pairedEnv(t)
	token := pairedToken(t, e, "t")
	for _, c := range []struct {
		method, path string
		status       int
	}{
		{"GET", "/peers", 403}, {"GET", "/logs", 403}, {"GET", "/assist/windows", 403}, {"POST", "/pair/code", 403}, {"GET", "/health", 403},
	} {
		if r := e.do(deadAddr, c.method, c.path, "{}", "X-Greenfield-Token", token); r.status != c.status {
			t.Errorf("%s %s: %d, want %d", c.method, c.path, r.status, c.status)
		}
	}
}

func TestAnUnknownRevokedOrExpiredTokenIsRefused(t *testing.T) {
	e := pairedEnv(t)
	if r := e.do(deadAddr, "GET", "/status", "", "X-Greenfield-Token", "nope"); r.status != 401 || r.errorCode() != "invalid_token" {
		t.Errorf("unknown token: %d %q", r.status, r.errorCode())
	}
	token := pairedToken(t, e, "t")
	id := e.h.c.Pairing.Devices()[0].ID
	if r := e.do("127.0.0.1", "POST", "/pair/revoke", `{"id":"`+id+`"}`); r.status != 200 {
		t.Fatalf("revoke: %d", r.status)
	}
	if r := e.do(deadAddr, "POST", "/text", text("a", "x"), "X-Greenfield-Token", token); r.status != 401 || len(e.ins.texts) != 0 {
		t.Errorf("a revoked token types: %d %v", r.status, e.ins.texts)
	}
}

func TestADeviceCanLeaveByItself(t *testing.T) {
	e := pairedEnv(t)
	token := pairedToken(t, e, "t")
	if r := e.do(deadAddr, "POST", "/pair/revoke", "{}", "X-Greenfield-Token", token); r.status != 200 {
		t.Fatalf("leave: %d", r.status)
	}
	if r := e.do(deadAddr, "GET", "/status", "", "X-Greenfield-Token", token); r.status != 401 {
		t.Errorf("after leaving: %d", r.status)
	}
	if r := e.do(deadAddr, "POST", "/pair/revoke", "{}"); r.status != 401 {
		t.Errorf("revoke with nothing: %d", r.status)
	}
}

func TestRevokeAllAndList(t *testing.T) {
	e := pairedEnv(t)
	a, b := pairedToken(t, e, "A"), pairedToken(t, e, "B")
	r := e.do("127.0.0.1", "GET", "/pair/devices", "")
	list, _ := r.body["devices"].([]any)
	if len(list) != 2 || strings.Contains(r.raw, a) || strings.Contains(r.raw, b) {
		t.Errorf("list: %s", r.raw)
	}
	if r := e.do("127.0.0.1", "POST", "/pair/revoke", `{"all":true}`); r.body["revoked"] != float64(2) {
		t.Errorf("revoke all: %s", r.raw)
	}
	if r := e.do(deadAddr, "GET", "/status", "", "X-Greenfield-Token", a); r.status != 401 {
		t.Errorf("after revoke all: %d", r.status)
	}
	if r := e.do("127.0.0.1", "POST", "/pair/revoke", `{"id":"nope"}`); r.status != 404 {
		t.Errorf("unknown id: %d", r.status)
	}
}

// --- the tailnet-identity path is untouched --------------------------------------------------------------------------------

func TestIdentityStillDecidesWithoutAToken(t *testing.T) {
	e := pairedEnv(t)
	for _, c := range []struct {
		from   string
		status int
	}{{phoneAddr, 200}, {otherAddr, 401}, {deadAddr, 503}} {
		if r := e.do(c.from, "GET", "/status", ""); r.status != c.status {
			t.Errorf("%s: %d, want %d", c.from, r.status, c.status)
		}
	}
}

func TestPairingDoesNotLetAnotherUserInWithoutAToken(t *testing.T) {
	e := pairedEnv(t)
	pairedToken(t, e, "t")
	if r := e.do(otherAddr, "POST", "/text", text("a", "x")); r.status != 401 || len(e.ins.texts) != 0 {
		t.Errorf("%d %v", r.status, e.ins.texts)
	}
}

func TestAProxiedLoopbackRequestIsNotTrustedAsLocal(t *testing.T) {
	// `tailscale serve` and the PWA's server reach the daemon from 127.0.0.1: that must not count as "this computer".
	e := pairedEnv(t)
	for _, h := range [][2]string{{"X-Forwarded-For", "100.99.1.2"}, {"Tailscale-User-Login", "stranger@example.com"}} {
		r := e.do("127.0.0.1", "POST", "/text", text("a", "x"), h[0], h[1])
		if r.status != 503 || r.errorCode() != "identity_unavailable" {
			t.Errorf("%s: %d %q", h[0], r.status, r.errorCode())
		}
	}
	if r := e.do("127.0.0.1", "GET", "/health", "", "X-Forwarded-For", "1.2.3.4"); r.status != 403 {
		t.Errorf("health through a proxy: %d", r.status)
	}
	if len(e.ins.texts) != 0 {
		t.Fatalf("typed %q", e.ins.texts)
	}
	token := pairedToken(t, e, "t")
	if r := e.do("127.0.0.1", "POST", "/text", text("b", "x"), "X-Forwarded-For", "1.2.3.4", "X-Greenfield-Token", token); r.status != 200 {
		t.Errorf("proxied with a valid token: %d", r.status)
	}
	if r := e.do("127.0.0.1", "POST", "/text", text("c", "x"), "X-Forwarded-For", "1.2.3.4", "X-Greenfield-Token", "bad"); r.status != 401 {
		t.Errorf("proxied with a wrong token: %d", r.status)
	}
}

func TestALoopbackRequestWithoutProxyHeadersIsStillLocal(t *testing.T) {
	e := pairedEnv(t)
	if r := e.do("127.0.0.1", "POST", "/text", text("a", "x")); r.status != 200 {
		t.Errorf("text: %d", r.status)
	}
	if r := e.do("127.0.0.1", "GET", "/health", ""); r.status != 200 {
		t.Errorf("health: %d", r.status)
	}
}

func TestATokenIsNotAKeyAndAKeyIsNotAToken(t *testing.T) {
	e := pairedEnv(t)
	if r := e.do(deadAddr, "GET", "/status", "", "X-Dictation-Key", "anything"); r.status != 401 {
		t.Errorf("a key opens the door: %d", r.status)
	}
	if r := e.do(deadAddr, "GET", "/status", "", "X-Greenfield-Token", "anything"); r.status != 401 || r.errorCode() != "invalid_token" {
		t.Errorf("a made-up token: %d %q", r.status, r.errorCode())
	}
}
