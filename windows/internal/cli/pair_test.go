package cli

import (
	"errors"
	"strings"
	"testing"
)

type call struct {
	method, path string
	body         map[string]any
}

// fakeLocal answers the daemon's loopback routes and remembers what was asked.
func fakeLocal(h *harness, status int, answer map[string]any, err error) *[]call {
	var calls []call
	h.d.Local = func(port int, method, path string, body map[string]any) (int, map[string]any, error) {
		calls = append(calls, call{method, path, body})
		return status, answer, err
	}
	return &calls
}

func TestPairShowsTheCode(t *testing.T) {
	h := newHarness(t)
	calls := fakeLocal(h, 200, map[string]any{"ok": true, "code": "ABCD-EFGH", "expires_in_s": float64(300), "name": "Example PC"}, nil)
	if code := h.run("pair"); code != 0 {
		t.Fatalf("exit %d: %s", code, h.err.String())
	}
	out := h.out.String()
	for _, want := range []string{"ABCD-EFGH", "Example PC", "within 5 minutes", "works once"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if len(*calls) != 1 || (*calls)[0].method != "POST" || (*calls)[0].path != "/pair/code" {
		t.Errorf("calls: %+v", *calls)
	}
}

func TestPairListsAndRevokes(t *testing.T) {
	h := newHarness(t)
	fakeLocal(h, 200, map[string]any{"ok": true, "devices": []any{
		map[string]any{"id": "a1b2c3", "name": "Ann's iPhone", "expires_at": "2027-01-16T08:00:00Z", "last_seen": nil},
	}}, nil)
	if h.run("pair", "--list") != 0 || !strings.Contains(h.out.String(), "a1b2c3  Ann's iPhone") || !strings.Contains(h.out.String(), "last seen never") {
		t.Errorf("list: %s", h.out.String())
	}
	h.out.Reset()
	calls := fakeLocal(h, 200, map[string]any{"ok": true, "revoked": float64(1)}, nil)
	if h.run("pair", "--revoke", "a1b2c3") != 0 || !strings.Contains(h.out.String(), "revoked a1b2c3") {
		t.Errorf("revoke: %s", h.out.String())
	}
	if (*calls)[0].path != "/pair/revoke" || (*calls)[0].body["id"] != "a1b2c3" {
		t.Errorf("calls: %+v", *calls)
	}
	h.out.Reset()
	calls = fakeLocal(h, 200, map[string]any{"ok": true, "revoked": float64(3)}, nil)
	if h.run("pair", "--revoke-all") != 0 || !strings.Contains(h.out.String(), "revoked 3 device(s)") || (*calls)[0].body["all"] != true {
		t.Errorf("revoke all: %s %+v", h.out.String(), *calls)
	}
}

func TestPairSaysWhyItCannot(t *testing.T) {
	h := newHarness(t)
	fakeLocal(h, 0, nil, errors.New("connection refused"))
	if h.run("pair") != 1 || !strings.Contains(h.err.String(), "not answering") {
		t.Errorf("daemon down: %s", h.err.String())
	}
	h.err.Reset()
	fakeLocal(h, 404, map[string]any{"ok": false, "error": "not_found"}, nil)
	if h.run("pair") != 1 || !strings.Contains(h.err.String(), "predates") {
		t.Errorf("old daemon: %s", h.err.String())
	}
	h.err.Reset()
	fakeLocal(h, 404, map[string]any{"ok": false, "error": "no_such_device", "message": "no paired device has that id"}, nil)
	if h.run("pair", "--revoke", "zz") != 1 || !strings.Contains(h.err.String(), "no paired device") {
		t.Errorf("unknown id: %s", h.err.String())
	}
	if h.run("pair", "--revoke") != 2 {
		t.Error("--revoke needs a value")
	}
}
