package tailnet

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const whoisMine = `{"Node":{"ID":1,"Name":"pc.tail1234.ts.net.","User":2000000000000001,"Tags":null},"UserProfile":{"ID":2000000000000001,"LoginName":"me@example.com","DisplayName":"Me"}}`
const whoisPhone = `{"Node":{"ID":2,"User":2000000000000001},"UserProfile":{"LoginName":"me@example.com"}}`
const whoisOther = `{"Node":{"ID":3,"User":42},"UserProfile":{"LoginName":"them@example.com"}}`
const whoisTagged = `{"Node":{"ID":4,"User":2000000000000001,"Tags":["tag:server"]},"UserProfile":{"LoginName":"tagged-devices"}}`

func TestParseWhois(t *testing.T) {
	w, ok := ParseWhois([]byte(whoisMine))
	if !ok || w.UserID != 2000000000000001 || w.Login != "me@example.com" || w.Tagged {
		t.Fatalf("%+v %v", w, ok)
	}
	if w, ok = ParseWhois([]byte(whoisTagged)); !ok || !w.Tagged {
		t.Fatalf("tagged: %+v %v", w, ok)
	}
	if w, ok = ParseWhois([]byte(`{"Node":{"User":7}}`)); !ok || w.Login != "user 7" {
		t.Fatalf("no profile: %+v %v", w, ok)
	}
	for _, bad := range []string{``, `{}`, `not json`, `{"Node":{}}`, `{"Node":{"User":"x"}}`} {
		if _, ok := ParseWhois([]byte(bad)); ok {
			t.Errorf("%q should not parse", bad)
		}
	}
}

func TestCompare(t *testing.T) {
	me := Whois{UserID: 1, Login: "me"}
	if p := Compare(Whois{UserID: 1, Login: "me"}, me); p.Kind != SameUser {
		t.Errorf("same user: %+v", p)
	}
	if p := Compare(Whois{UserID: 2, Login: "other"}, me); p.Kind != OtherUser || p.Login != "other" {
		t.Errorf("other user: %+v", p)
	}
	// A tagged device never counts as the same user, even when the user id matches.
	if p := Compare(Whois{UserID: 1, Login: "x", Tagged: true}, me); p.Kind != OtherUser || p.Login != "a tagged device" {
		t.Errorf("tagged peer: %+v", p)
	}
	if p := Compare(Whois{UserID: 1}, Whois{UserID: 1, Tagged: true}); p.Kind != OtherUser {
		t.Errorf("tagged self: %+v", p)
	}
}

type fakeTool struct {
	calls atomic.Int32
	out   map[string]string // address -> json
	fail  bool
	gone  bool
}

func (f *fakeTool) run(args ...string) (int, []byte, string, bool) {
	f.calls.Add(1)
	if f.gone {
		return 0, nil, "", false
	}
	if f.fail {
		return 1, nil, "Tailscale is stopped", true
	}
	if args[0] == "status" {
		return 0, []byte(statusJSON), "", true
	}
	if j, ok := f.out[args[2]]; ok {
		return 0, []byte(j), "", true
	}
	return 1, nil, "no match for " + args[2], true
}

func newCLI(f *fakeTool, now *time.Time) *CLI {
	return NewCLIWith(f.run, func() string { return "100.64.0.10" }, func() time.Time { return *now })
}

func TestIdentifyAsksTailscaleAndCaches(t *testing.T) {
	now := time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &fakeTool{out: map[string]string{"100.64.0.10": whoisMine, "100.64.0.20": whoisPhone, "100.64.0.30": whoisOther, "100.64.0.40": whoisTagged}}
	c := newCLI(f, &now)
	if p := c.Identify("100.64.0.20"); p.Kind != SameUser || p.Login != "me@example.com" {
		t.Errorf("phone of the same user: %+v", p)
	}
	if p := c.Identify("100.64.0.30"); p.Kind != OtherUser || p.Login != "them@example.com" {
		t.Errorf("other user: %+v", p)
	}
	if p := c.Identify("100.64.0.40"); p.Kind != OtherUser {
		t.Errorf("tagged: %+v", p)
	}
	if got := c.SelfLogin(); got != "me@example.com" {
		t.Errorf("self login %q", got)
	}
	before := f.calls.Load()
	c.Identify("100.64.0.20")
	if f.calls.Load() != before {
		t.Errorf("a repeat within a minute must come from the cache")
	}
	now = now.Add(61 * time.Second)
	c.Identify("100.64.0.20")
	if f.calls.Load() == before {
		t.Errorf("after a minute the answer is asked for again")
	}
}

func TestIdentifyFailsClosed(t *testing.T) {
	now := time.Now()
	// The tool is missing.
	c := newCLI(&fakeTool{gone: true}, &now)
	if p := c.Identify("100.64.0.20"); p.Kind != Unknown || !strings.Contains(p.Why, "missing") {
		t.Errorf("missing tool: %+v", p)
	}
	// Tailscale answers with an error: unknown, with its words.
	c = newCLI(&fakeTool{fail: true}, &now)
	if p := c.Identify("100.64.0.20"); p.Kind != Unknown || !strings.Contains(p.Why, "Tailscale is stopped") {
		t.Errorf("tailscale error: %+v", p)
	}
	if c.SelfLogin() != "" {
		t.Errorf("no self login without an answer")
	}
	// The peer is not known to Tailscale but this computer is.
	c = newCLI(&fakeTool{out: map[string]string{"100.64.0.10": whoisMine}}, &now)
	if p := c.Identify("100.99.99.99"); p.Kind != Unknown {
		t.Errorf("unknown peer must be denied: %+v", p)
	}
	// No tailnet address of our own.
	c = NewCLIWith((&fakeTool{}).run, func() string { return "" }, time.Now)
	if p := c.Identify("100.64.0.20"); p.Kind != Unknown || !strings.Contains(p.Why, "no tailnet address") {
		t.Errorf("no own address: %+v", p)
	}
	// A failure is cached only briefly, so a restarting Tailscale recovers.
	f := &fakeTool{fail: true}
	c = newCLI(f, &now)
	c.Identify("100.64.0.20")
	now = now.Add(4 * time.Second)
	f.fail, f.out = false, map[string]string{"100.64.0.10": whoisMine, "100.64.0.20": whoisPhone}
	if p := c.Identify("100.64.0.20"); p.Kind != SameUser {
		t.Errorf("recovery after 4s: %+v", p)
	}
}

func TestInTailnetRange(t *testing.T) {
	for ip, want := range map[string]bool{"100.64.0.1": true, "100.127.255.254": true, "100.63.255.255": false, "100.128.0.1": false, "192.168.1.5": false, "127.0.0.1": false, "fd7a:115c:a1e0::1": false} {
		if got := InTailnetRange(net.ParseIP(ip)); got != want {
			t.Errorf("%s: %v want %v", ip, got, want)
		}
	}
}

const statusJSON = `{
 "Self": {"HostName":"pc","DNSName":"pc.tail1234.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::1"],"OS":"windows","Online":true,"UserID":2000000000000001},
 "Peer": {
  "k1": {"HostName":"studio","DNSName":"studio.tail1234.ts.net.","TailscaleIPs":["100.64.0.30","fd7a::3"],"OS":"macOS","Online":true,"UserID":2000000000000001},
  "k2": {"HostName":"phone","DNSName":"phone.tail1234.ts.net.","TailscaleIPs":["100.64.0.20"],"OS":"iOS","Online":true,"UserID":2000000000000001},
  "k3": {"HostName":"old","DNSName":"old.tail1234.ts.net.","TailscaleIPs":["100.64.0.31"],"OS":"macOS","Online":false,"UserID":2000000000000001},
  "k4": {"HostName":"theirs","DNSName":"theirs.tail1234.ts.net.","TailscaleIPs":["100.64.0.32"],"OS":"macOS","Online":true,"UserID":9},
  "k5": {"HostName":"laptop","DNSName":"laptop.tail1234.ts.net.","TailscaleIPs":["100.64.0.33"],"OS":"windows","Online":true,"UserID":2000000000000001},
  "k6": {"HostName":"quiet","DNSName":"quiet.tail1234.ts.net.","TailscaleIPs":["100.64.0.34"],"OS":"windows","Online":true,"UserID":2000000000000001}
 }
}`

func TestParseStatus(t *testing.T) {
	me, peers, ok := ParseStatus([]byte(statusJSON))
	if !ok || me.DNSName != "pc.tail1234.ts.net" || me.IP != "100.64.0.10" || len(peers) != 6 {
		t.Fatalf("%+v %d %v", me, len(peers), ok)
	}
	if peers[0].DNSName != "laptop.tail1234.ts.net" {
		t.Errorf("peers sorted by name: %v", peers[0].DNSName)
	}
	for _, bad := range []string{``, `{}`, `{"Self":{}}`} {
		if _, _, ok := ParseStatus([]byte(bad)); ok {
			t.Errorf("%q should not parse", bad)
		}
	}
}

func TestFinderProbesOnlyOnlineSameUserComputersWithADaemon(t *testing.T) {
	var mu sync.Mutex
	var probed []string
	finder := &Finder{
		StatusJSON: func() []byte { return []byte(statusJSON) },
		Probe: func(n Node) *Snapshot {
			mu.Lock()
			probed = append(probed, n.HostName)
			mu.Unlock()
			switch n.HostName {
			case "studio":
				return &Snapshot{Name: "Studio Mac", Version: "0.4.1"}
			case "laptop":
				return &Snapshot{Name: "Laptop", Version: "0.4.0"}
			}
			return nil // "quiet" runs no daemon
		},
		MyName:    func() string { return "This PC" },
		MyVersion: "0.4.0",
	}
	got := finder.Computers()
	want := []Computer{{"This PC", "pc.tail1234.ts.net", "0.4.0", true}, {"Laptop", "laptop.tail1234.ts.net", "0.4.0", false}, {"Studio Mac", "studio.tail1234.ts.net", "0.4.1", false}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("got %v\nwant %v", got, want)
	}
	for _, h := range probed {
		if h == "phone" || h == "old" || h == "theirs" {
			t.Errorf("must not probe %s", h)
		}
	}
	n := len(probed)
	finder.Computers()
	if len(probed) != n {
		t.Errorf("the answer is cached for 20 seconds")
	}
}

func TestFinderWithNoTailscale(t *testing.T) {
	f := &Finder{StatusJSON: func() []byte { return nil }, Probe: nil, MyName: func() string { return "x" }}
	if got := f.Computers(); got == nil || len(got) != 0 {
		t.Errorf("want an empty (non-nil) list, got %v", got)
	}
}

func TestHTTPProbeReadsAStatusAnswer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/status" || r.Header.Get("X-Greenfield-App") != "" {
			w.WriteHeader(404)
			return
		}
		w.Write([]byte(`{"ok":true,"name":"Probed","version":"0.4.2"}`))
	}))
	defer srv.Close()
	host, portStr, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	port, _ := strconv.Atoi(portStr)
	s := HTTPProbe(port, time.Second)(Node{IP: host})
	if s == nil || s.Name != "Probed" || s.Version != "0.4.2" {
		t.Errorf("%+v", s)
	}
	if HTTPProbe(1, 200*time.Millisecond)(Node{IP: "127.0.0.1"}) != nil {
		t.Errorf("a closed port is not a daemon")
	}
}

func TestAddLinkMatchesTheMacEncoding(t *testing.T) {
	link := AddLink("Example PC & Co", "pc.tail1234.ts.net")
	if link != "greenfield://add?name=Example%20PC%20%26%20Co&address=pc.tail1234.ts.net" {
		t.Errorf("link %q", link)
	}
	name, address, ok := ParseAddLink(link)
	if !ok || name != "Example PC & Co" || address != "pc.tail1234.ts.net" {
		t.Errorf("round trip: %q %q %v", name, address, ok)
	}
	if AddLink("a+b=c#d", "x") != "greenfield://add?name=a%2Bb%3Dc%23d&address=x" {
		t.Errorf("reserved characters: %q", AddLink("a+b=c#d", "x"))
	}
	if _, _, ok := ParseAddLink("https://add?address=x"); ok {
		t.Errorf("wrong scheme")
	}
}
