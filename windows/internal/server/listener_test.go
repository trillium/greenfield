package server

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestListenersServeOnTheAddressAndStop(t *testing.T) {
	e := newEnv(t)
	l := &Listeners{Port: 0, Bind: "127.0.0.1", Handler: e.h}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { l.Run(ctx); close(done) }()
	waitFor(t, "listening", func() bool { return len(l.Listening()) == 1 })
	addr := l.Listening()[0]
	if !strings.HasPrefix(addr, "127.0.0.1:") {
		t.Fatalf("listening on %q", addr)
	}
	resp, err := http.Get("http://" + addr + "/status")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"service":"greenfield-inserter"`) || !resp.Close {
		t.Errorf("%d %s %v", resp.StatusCode, body, resp.Header)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
	if len(l.Listening()) != 0 {
		t.Errorf("still listening: %v", l.Listening())
	}
}

func TestTailnetListenerWaitsForTailscaleAndFollowsItsAddress(t *testing.T) {
	e := newEnv(t)
	var ip atomic.Value
	ip.Store("")
	l := &Listeners{Port: 0, Handler: e.h, TailnetIP: func() string { return ip.Load().(string) }, Poll: 20 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go l.Run(ctx)

	// Loopback is up at once; with no tailnet address nothing else is.
	waitFor(t, "loopback", func() bool { return len(l.Listening()) == 1 })
	if !strings.HasPrefix(l.Listening()[0], "127.0.0.1:") {
		t.Fatalf("%v", l.Listening())
	}
	// Tailscale comes up (the loopback address stands in for the tailnet address; macOS has no other one by default).
	loopbackPort := l.Listening()[0]
	ip.Store("127.0.0.1")
	waitFor(t, "tailnet address", func() bool { return len(l.Listening()) == 2 })
	tailnetPort := ""
	for _, a := range l.Listening() {
		if a != loopbackPort {
			tailnetPort = a
		}
	}
	// The address changes ("localhost" is the same machine under another name): the old listener goes away and a new one comes up.
	ip.Store("localhost")
	waitFor(t, "rebind", func() bool {
		got := l.Listening()
		return len(got) == 2 && got[0] != tailnetPort && got[1] != tailnetPort
	})
	// The address disappears: only loopback stays.
	ip.Store("")
	waitFor(t, "loopback only", func() bool { return len(l.Listening()) == 1 })
}
