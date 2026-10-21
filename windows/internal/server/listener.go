package server

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	"greenfield-inserter/internal/tailnet"
)

// Listeners serves the handler on this computer's tailnet address and on loopback, and on no other interface (not the LAN, not
// 0.0.0.0): plain HTTP is acceptable only because tailnet members alone can reach it. Each listener waits for its address and
// re-binds if it goes away, so the daemon survives Tailscale starting late, restarting or changing address.
type Listeners struct {
	Port    int
	Bind    string // an explicit address replaces both defaults ("" = tailnet + loopback)
	Handler http.Handler
	Log     func(string)
	// TailnetIP is this computer's tailnet address ("" when there is none); tailnet.IPv4 by default.
	TailnetIP func() string
	// Poll is how often a tailnet listener checks that its address is still the tailnet address (10 s by default).
	Poll time.Duration

	mu     sync.Mutex
	active map[string]bool
}

// Listening is the addresses being served now, as "ip:port", sorted; /status reports them as `listen`.
func (l *Listeners) Listening() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]string, 0, len(l.active))
	for a := range l.active {
		out = append(out, a)
	}
	sort.Strings(out)
	return out
}

func (l *Listeners) setActive(addr string, on bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.active == nil {
		l.active = map[string]bool{}
	}
	if on {
		l.active[addr] = true
	} else {
		delete(l.active, addr)
	}
}

func (l *Listeners) log(m string) {
	if l.Log != nil {
		l.Log(m)
	}
}

// Run serves until ctx is cancelled.
func (l *Listeners) Run(ctx context.Context) {
	if l.TailnetIP == nil {
		l.TailnetIP = tailnet.IPv4
	}
	if l.Poll == 0 {
		l.Poll = 10 * time.Second
	}
	var wg sync.WaitGroup
	start := func(fixed string) {
		wg.Add(1)
		go func() { defer wg.Done(); l.runOne(ctx, fixed) }()
	}
	if l.Bind != "" {
		start(l.Bind)
	} else {
		start("127.0.0.1")
		start("") // whatever the tailnet address currently is
	}
	wg.Wait()
}

func sleep(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}

// runOne: fixed "" means "whatever the tailnet address currently is".
func (l *Listeners) runOne(ctx context.Context, fixed string) {
	waitingLogged := false
	lastFailure := ""
	for ctx.Err() == nil {
		addr := fixed
		if addr == "" {
			if addr = l.TailnetIP(); addr == "" {
				if !waitingLogged {
					l.log("no tailnet address yet; waiting for Tailscale")
					waitingLogged = true
				}
				if !sleep(ctx, time.Second) {
					return
				}
				continue
			}
		}
		waitingLogged = false
		ln, err := net.Listen("tcp4", net.JoinHostPort(addr, strconv.Itoa(l.Port)))
		if err != nil {
			// Said once per distinct failure, not every 5 seconds.
			if msg := fmt.Sprintf("cannot listen on %s:%d: %v", addr, l.Port, err); msg != lastFailure {
				l.log(msg)
				lastFailure = msg
			}
			if !sleep(ctx, 5*time.Second) {
				return
			}
			continue
		}
		lastFailure = ""
		bound := ln.Addr().String()
		l.log("listening on " + bound)
		l.setActive(bound, true)
		l.serve(ctx, ln, addr, fixed == "")
		l.setActive(bound, false)
		l.log("listener on " + addr + " stopped" + map[bool]string{true: "; rebinding", false: ""}[ctx.Err() == nil])
	}
}

func (l *Listeners) serve(ctx context.Context, ln net.Listener, addr string, followTailnet bool) {
	srv := &http.Server{Handler: l.Handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second}
	srv.SetKeepAlivesEnabled(false) // one short-lived connection per request, like the Mac daemon
	done := make(chan struct{})
	go func() {
		defer close(done)
		t := time.NewTicker(l.Poll)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				srv.Close()
				return
			case <-t.C:
				if followTailnet && l.TailnetIP() != addr {
					srv.Close()
					return
				}
			}
		}
	}()
	_ = srv.Serve(ln)
	srv.Close()
	<-done
}
