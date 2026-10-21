package server

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"greenfield-inserter/internal/inserter"
)

// The contract tests tie this daemon to the two places the contract is recorded:
//   - the phone's recorded requests (App/Tests/Fixtures/request-*.json): the daemon must accept exactly what the phone sends;
//   - the Mac daemon's recorded answers (mac/Tests/Fixtures/*.json): every field the Mac reports, this daemon reports with the
//     same JSON type, so the phone's parsing of a Mac works on a Windows computer unchanged.
// Both sets are read from the repository when it is present and skipped when windows/ is copied out alone. This daemon's own recorded
// answers are in testdata/ (re-record deliberately with RECORD_FIXTURES=1 go test ./internal/server -run TestRecorded).

const (
	phoneFixtures = "../../../App/Tests/Fixtures"
	macFixtures   = "../../../mac/Tests/Fixtures"
)

func readFixture(t *testing.T, dir, name string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Skipf("%s not available: %v", filepath.Join(dir, name), err)
	}
	var o map[string]any
	if err := json.Unmarshal(data, &o); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return o
}

func TestTheDaemonAcceptsExactlyWhatThePhoneRecordsItSends(t *testing.T) {
	e := newEnv(t)
	fill := func(fx map[string]any) (headers []string, body string) {
		for k, v := range fx["headers"].(map[string]any) {
			s := v.(string)
			switch {
			case k == "X-Greenfield-App":
				s = "0.4.0" // the app's own version, from its tag
			case strings.HasPrefix(s, "<only when"):
				continue // an optional header the phone sends only under Advanced
			}
			headers = append(headers, k, s)
		}
		if b, ok := fx["body"].(map[string]any); ok {
			if id, _ := b["id"].(string); strings.HasPrefix(id, "<") {
				b["id"] = "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E-" + time.Now().Format("150405.000000")
			}
			if tx, _ := b["text"].(string); strings.HasPrefix(tx, "<") {
				b["text"] = "Hello, world."
			}
			raw, _ := json.Marshal(b)
			body = string(raw)
		}
		return
	}
	for _, name := range []string{"request-status.json", "request-text.json", "request-text-multiline.json"} {
		fx := readFixture(t, phoneFixtures, name)
		headers, body := fill(fx)
		for _, path := range []string{fx["path"].(string)} {
			if r := e.do(phoneAddr, fx["method"].(string), path, body, headers...); r.status != 200 || r.body["ok"] != true {
				t.Errorf("%s: %d %v", name, r.status, r.body)
			}
		}
	}
	// The multi-line sample arrives with every line break kept.
	if got := e.ins.texts[len(e.ins.texts)-1]; got != "Dear team,\n\nThe build is green.\nThanks\n" {
		t.Errorf("multi-line text typed as %q", got)
	}
	// /peers takes the same request shape as /status.
	if r := e.do(phoneAddr, "GET", "/peers", "", "X-Greenfield-App", "0.4.0"); r.status != 200 {
		t.Errorf("peers: %d", r.status)
	}
}

// shape describes the JSON types of an object, recursively; a list is described by the type of its first element.
func shape(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, e := range x {
			if strings.HasPrefix(k, "_") {
				continue
			}
			out[k] = shape(e)
		}
		return out
	case []any:
		if len(x) == 0 {
			return "[]"
		}
		return []any{shape(x[0])}
	case string:
		return "string"
	case float64:
		return "number"
	case bool:
		return "bool"
	case nil:
		return "null"
	}
	return "?"
}

// covers checks that mine has every key of theirs with the same type. Empty lists, and null where the other side has a value, are
// compatible with anything in their place (they carry no elements to compare).
func covers(path string, theirs, mine any) []string {
	var problems []string
	switch t := theirs.(type) {
	case map[string]any:
		m, ok := mine.(map[string]any)
		if !ok {
			return []string{path + ": not an object"}
		}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if _, has := m[k]; !has {
				problems = append(problems, path+"."+k+": missing")
				continue
			}
			problems = append(problems, covers(path+"."+k, t[k], m[k])...)
		}
	case []any:
		if m, ok := mine.([]any); ok && len(t) > 0 && len(m) > 0 {
			return covers(path+"[]", t[0], m[0])
		}
		if _, ok := mine.([]any); !ok && mine != "[]" {
			return []string{path + ": not a list"}
		}
	default:
		if t != mine && t != "null" && mine != "null" && t != "[]" && mine != "[]" {
			problems = append(problems, path+": type "+toString(mine)+", the Mac has "+toString(t))
		}
	}
	return problems
}

func toString(v any) string { b, _ := json.Marshal(v); return string(b) }

func TestStatusHasEveryFieldTheMacReportsWithTheSameTypes(t *testing.T) {
	mac := readFixture(t, macFixtures, "status-ready.json")
	e := newEnv(t)
	e.h.c.Record.RecordSuccess("selftest") // so delivery.at/source are present like the Mac's sample
	*e.clock = epoch.Add(time.Hour)
	e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.4.0")
	r := e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.4.0")
	var mine map[string]any
	_ = json.Unmarshal([]byte(r.raw), &mine)
	if problems := covers("status", shape(mac), shape(mine)); len(problems) > 0 {
		t.Errorf("the phone reads these from a Mac and would not find them here:\n%s", strings.Join(problems, "\n"))
	}
	// The one field the Mac does not have.
	if mine["platform"] != "windows" {
		t.Errorf("platform %v", mine["platform"])
	}
}

func TestStatus426HasTheMacBody(t *testing.T) {
	for name, app := range map[string]string{"status-426-app-too-old.json": "0.1.0", "status-426-app-too-new.json": "0.9.0"} {
		mac := readFixture(t, macFixtures, name)
		e := newEnv(t)
		r := e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", app)
		var mine map[string]any
		_ = json.Unmarshal([]byte(r.raw), &mine)
		if int(mac["_http_status"].(float64)) != r.status {
			t.Errorf("%s: status %d, the Mac answers %v", name, r.status, mac["_http_status"])
		}
		if problems := covers(name, shape(mac), shape(mine)); len(problems) > 0 {
			t.Errorf("%s:\n%s", name, strings.Join(problems, "\n"))
		}
		if mac["error"] != mine["error"] {
			t.Errorf("%s: error %v, the Mac says %v", name, mine["error"], mac["error"])
		}
	}
}

func TestPeersHasTheMacShape(t *testing.T) {
	mac := readFixture(t, macFixtures, "peers-two-macs.json")
	e := newEnv(t)
	r := e.do(phoneAddr, "GET", "/peers", "")
	var mine map[string]any
	_ = json.Unmarshal([]byte(r.raw), &mine)
	if problems := covers("peers", shape(mac), shape(mine)); len(problems) > 0 {
		t.Errorf("%s", strings.Join(problems, "\n"))
	}
	// And no field the phone does not know about sneaks into a peer.
	for _, p := range mine["peers"].([]any) {
		keys := []string{}
		for k := range p.(map[string]any) {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if !reflect.DeepEqual(keys, []string{"address", "name", "self", "version"}) {
			t.Errorf("peer fields %v", keys)
		}
	}
}

// The error codes the phone acts on (docs/mac-contract.md) are all produced here with the HTTP status the phone maps them to.
func TestEveryErrorCodeOfTheContractHasItsStatus(t *testing.T) {
	e := newEnv(t)
	seen := map[string]int{}
	note := func(r reply) {
		if c := r.errorCode(); c != "" {
			seen[c] = r.status
		}
	}
	note(e.do(otherAddr, "GET", "/status", ""))
	note(e.do(deadAddr, "GET", "/status", ""))
	note(e.do(phoneAddr, "POST", "/text", "nope"))
	note(e.do(phoneAddr, "POST", "/text", `{"id":"a","text":"`+strings.Repeat("x", MaxTextBytes+1)+`"}`))
	e.probe.locked = true
	note(e.do(phoneAddr, "POST", "/text", text("l", "x")))
	e.probe.locked, e.probe.secure = false, true
	note(e.do(phoneAddr, "POST", "/text", text("s", "x")))
	e.probe.secure, e.probe.blocked = false, "x"
	note(e.do(phoneAddr, "POST", "/text", text("a", "x")))
	e.probe.blocked = ""
	e.ins.err = inserter.ErrNotDelivered
	note(e.do(phoneAddr, "POST", "/text", text("n", "x")))
	e.ins.err = assertErr("x")
	note(e.do(phoneAddr, "POST", "/text", text("f", "x")))
	note(e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.1.0"))
	note(e.do(phoneAddr, "GET", "/logs?tail=0", ""))
	note(e.do(phoneAddr, "GET", "/assist/windows", ""))
	want := map[string]int{
		"unauthorized": 401, "identity_unavailable": 503, "bad_request": 400, "too_large": 413, "screen_locked": 423, "secure_input": 409,
		"accessibility_not_granted": 503, "not_delivered": 502, "insert_failed": 500, "app_too_old": 426, "assist_off": 404,
	}
	for code, status := range want {
		if seen[code] != status {
			t.Errorf("%s: status %d, want %d", code, seen[code], status)
		}
	}
}

// --- this daemon's own recorded answers -----------------------------------------------------------------------------------

func recordedStatus(t *testing.T, mutate func(*env)) reply {
	t.Helper()
	e := newEnv(t)
	e.h.started = epoch
	e.h.c.Record.RecordSuccess("selftest")
	e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.4.0")
	*e.clock = epoch.Add(time.Hour)
	if mutate != nil {
		mutate(e)
	}
	return e.do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.4.0")
}

func TestRecordedAnswers(t *testing.T) {
	samples := map[string]func() (reply, string){
		"status-ready.json": func() (reply, string) {
			return recordedStatus(t, nil), "Recorded from the real handler (RECORD_FIXTURES=1). A Windows computer that is ready."
		},
		"status-input-blocked.json": func() (reply, string) {
			return recordedStatus(t, func(e *env) { e.probe.blocked = "an app running as administrator has the focus" }), "An app running as administrator has the focus: accessibility is false."
		},
		"status-locked.json": func() (reply, string) {
			return recordedStatus(t, func(e *env) { e.probe.locked = true }), "The screen is locked."
		},
		"status-426-app-too-old.json": func() (reply, string) {
			return newEnv(t).do(phoneAddr, "GET", "/status", "", "X-Greenfield-App", "0.1.0"), "An app older than min_client_version."
		},
		"peers-two-computers.json": func() (reply, string) {
			return newEnv(t).do(phoneAddr, "GET", "/peers", ""), "GET /peers: this PC and a Mac."
		},
	}
	names := make([]string, 0, len(samples))
	for n := range samples {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		r, comment := samples[name]()
		var body map[string]any
		_ = json.Unmarshal([]byte(r.raw), &body)
		body["_comment"] = comment + " HTTP status in _http_status."
		body["_http_status"] = r.status
		pretty, _ := json.MarshalIndent(body, "", "  ")
		pretty = append(pretty, '\n')
		path := filepath.Join("..", "..", "testdata", name)
		if os.Getenv("RECORD_FIXTURES") != "" {
			_ = os.MkdirAll(filepath.Dir(path), 0o755)
			if err := os.WriteFile(path, pretty, 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		want, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s is not recorded yet: RECORD_FIXTURES=1 go test ./internal/server -run TestRecordedAnswers", name)
		}
		if !bytes.Equal(want, pretty) {
			t.Errorf("%s drifted from what the handler answers; if that is deliberate re-record it with RECORD_FIXTURES=1.\nwant: %s\n got: %s", name, want, pretty)
		}
	}
}
