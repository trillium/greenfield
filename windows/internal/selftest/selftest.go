// Package selftest proves, without a phone, that text really arrives: it opens a small window with a focused text field, sends
// unique harmless strings through the real daemon on loopback (POST /text), reads the field back, checks that a line break arrived
// as a line break, closes the window and says PASS, or FAIL naming the step with what is wrong, why and the fix. The result is
// written to the delivery ledger that `health` and GET /status report from. The window takes the keyboard focus for a few seconds.
package selftest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"greenfield-inserter/internal/health"
	"greenfield-inserter/internal/inserter"
)

// Field is a window with a text field that has the keyboard focus.
type Field interface {
	Open() error
	// Focused: the field has the keyboard focus now.
	Focused() bool
	// Text is the field's text, ok false when it cannot be read.
	Text() (text string, ok bool)
	Close()
}

// Daemon sends a text through the real daemon.
type Daemon interface {
	Post(id, text string) (status int, body map[string]any, err error)
}

// Recorder keeps the evidence for health.
type Recorder interface {
	RecordSuccess(source string)
	RecordFailure(source, detail string)
}

// Result of a run.
type Result struct {
	Pass    bool
	Step    string
	Problem string
	Why     string
	Fix     string
	Lines   []string
}

// Text renders the result.
func (r Result) Text() string {
	var b strings.Builder
	for _, l := range r.Lines {
		b.WriteString("  " + l + "\n")
	}
	if r.Pass {
		b.WriteString("PASS: text typed through the daemon arrived in a real field, and a line break arrived as a line break.\n")
		return b.String()
	}
	fmt.Fprintf(&b, "FAIL at step %q: %s\n", r.Step, r.Problem)
	if r.Why != "" {
		fmt.Fprintf(&b, "  why: %s\n", r.Why)
	}
	if r.Fix != "" {
		fmt.Fprintf(&b, "  fix: %s\n", r.Fix)
	}
	return b.String()
}

// blockers are the health checks that make a selftest pointless. The state of the app in front (input, secure-input) is not one:
// the selftest brings its own window to the front.
var blockers = map[string]bool{"daemon": true, "tailscale-cli": true, "tailnet": true, "auth": true, "listening": true, "unlocked": true}

// Run does the whole test. unique makes the test strings; wait is how long the field gets to take the focus.
func Run(checks []health.Check, f Field, d Daemon, rec Recorder, unique func() string, wait time.Duration) Result {
	var res Result
	say := func(format string, a ...any) { res.Lines = append(res.Lines, fmt.Sprintf(format, a...)) }
	fail := func(step, problem, why, fix string) Result {
		res.Step, res.Problem, res.Why, res.Fix = step, problem, why, fix
		if rec != nil && step != "preflight" {
			rec.RecordFailure("selftest", problem)
		}
		return res
	}

	for _, c := range checks {
		if c.Status == health.Fail && blockers[c.ID] {
			return fail("preflight", c.Title+": "+c.Detail, c.Why, c.Fix)
		}
	}
	say("preflight: the daemon is running and can tell who is calling")

	if err := f.Open(); err != nil {
		return fail("window", "could not open the test window: "+err.Error(), "The selftest types into a small window of its own.",
			"Run it from a normal desktop session (not a service or a disconnected remote session).")
	}
	defer f.Close()
	deadline := time.Now().Add(wait)
	for !f.Focused() {
		if time.Now().After(deadline) {
			return fail("focus", "the test window did not get the keyboard focus", "Windows does not let a background program take the focus from another window.",
				"Run `greenfield-inserter selftest` from a terminal you are typing in (it is allowed to take the focus), and do not click away while it runs.")
		}
		time.Sleep(25 * time.Millisecond)
	}
	say("window: a test field has the keyboard focus")

	one := "greenfield selftest " + unique()
	if r, ok := sendAndRead(&res, f, d, "send", "id-a-"+unique(), one, one); !ok {
		return fail(r.step, r.problem, r.why, r.fix)
	}
	say("text: %q arrived in the field", one)

	two := "line one\nline two"
	if r, ok := sendAndRead(&res, f, d, "line breaks", "id-b-"+unique(), two, "line one\nline two"); !ok {
		return fail(r.step, r.problem, r.why, r.fix)
	}
	say("line breaks: a line feed arrived as a Return key press (two lines in the field)")

	if rec != nil {
		rec.RecordSuccess("selftest")
	}
	res.Pass = true
	return res
}

type stepFailure struct{ step, problem, why, fix string }

func sendAndRead(res *Result, f Field, d Daemon, step, id, text, want string) (stepFailure, bool) {
	status, body, err := d.Post(id, text)
	if err != nil {
		return stepFailure{step, "the daemon did not answer POST /text: " + err.Error(), "The selftest sends through the real daemon on loopback.", "Run `greenfield-inserter health`."}, false
	}
	if status != 200 {
		code, _ := body["error"].(string)
		msg, _ := body["message"].(string)
		return stepFailure{step, fmt.Sprintf("the daemon refused the test text: HTTP %d %s (%s)", status, code, msg), "The same refusal would stop real dictation.",
			"Run `greenfield-inserter doctor`."}, false
	}
	// The field is read after the daemon answered; give a slow app a moment.
	var got string
	var readable bool
	for i := 0; i < 20; i++ {
		got, readable = f.Text()
		if readable && strings.Contains(inserter.NormalizeNewlines(got), want) {
			return stepFailure{}, true
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !readable {
		return stepFailure{step, "the test field could not be read back", "The check reads the text of its own window.", "Run the selftest again; if it repeats, this is a bug in greenfield-inserter."}, false
	}
	return stepFailure{step, "the daemon said it typed the text but the test field does not contain it",
		"Windows accepted the keys but they did not reach the field: usually another window took the focus while the test ran, or greenfield-inserter runs as a normal program and the foreground window belongs to an administrator program.",
		"Do not click or type while the selftest runs; if it repeats, run greenfield-inserter from an administrator terminal."}, false
}

// Loopback posts to the daemon on 127.0.0.1.
type Loopback struct {
	Port    int
	Timeout time.Duration
}

// Post implements Daemon.
func (l Loopback) Post(id, text string) (int, map[string]any, error) {
	payload, _ := json.Marshal(map[string]any{"id": id, "text": text, "source": "selftest"})
	client := &http.Client{Timeout: l.Timeout}
	resp, err := client.Post("http://"+net.JoinHostPort("127.0.0.1", strconv.Itoa(l.Port))+"/text", "application/json", bytes.NewReader(payload))
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var out map[string]any
	_ = json.Unmarshal(data, &out)
	return resp.StatusCode, out, nil
}
