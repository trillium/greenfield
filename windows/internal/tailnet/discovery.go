package tailnet

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// Node is one node of the tailnet, from `tailscale status --json`.
type Node struct {
	HostName string
	DNSName  string // full MagicDNS name without the trailing dot
	IP       string
	OS       string
	Online   bool
	UserID   int64
}

// ParseStatus reads `tailscale status --json`: this node and its peers (sorted by name).
func ParseStatus(data []byte) (me Node, peers []Node, ok bool) {
	var o struct {
		Self json.RawMessage            `json:"Self"`
		Peer map[string]json.RawMessage `json:"Peer"`
	}
	if json.Unmarshal(data, &o) != nil || len(o.Self) == 0 {
		return Node{}, nil, false
	}
	me, ok = parseNode(o.Self)
	if !ok {
		return Node{}, nil, false
	}
	for _, raw := range o.Peer {
		if n, good := parseNode(raw); good {
			peers = append(peers, n)
		}
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].DNSName < peers[j].DNSName })
	return me, peers, true
}

func parseNode(raw json.RawMessage) (Node, bool) {
	var o struct {
		HostName     string   `json:"HostName"`
		DNSName      string   `json:"DNSName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
		OS           string   `json:"OS"`
		Online       bool     `json:"Online"`
		UserID       *int64   `json:"UserID"`
	}
	if json.Unmarshal(raw, &o) != nil || o.DNSName == "" || o.UserID == nil {
		return Node{}, false
	}
	ip := ""
	for _, a := range o.TailscaleIPs {
		if !strings.Contains(a, ":") {
			ip = a
			break
		}
	}
	if ip == "" {
		return Node{}, false
	}
	return Node{HostName: o.HostName, DNSName: strings.TrimSuffix(o.DNSName, "."), IP: ip, OS: o.OS, Online: o.Online, UserID: *o.UserID}, true
}

// Computer is a computer running greenfield-inserter, as the phone lists it.
type Computer struct {
	Name    string `json:"name"`
	Address string `json:"address"` // MagicDNS name: stable, and what the phone connects to
	Version string `json:"version"`
	Self    bool   `json:"self"`
}

// Discovery lists the computers of this tailnet user that run the daemon.
type Discovery interface {
	Computers() []Computer
}

// Snapshot is what a probed daemon says about itself.
type Snapshot struct {
	Name    string
	Version string
}

// Probe asks one node's daemon for GET /status (nil when it does not answer like a daemon).
type Probe func(Node) *Snapshot

// RunsDaemon says which operating systems have a daemon of this project: the Mac one and this one.
func RunsDaemon(os string) bool {
	switch strings.ToLower(os) {
	case "macos", "windows":
		return true
	}
	return false
}

// Finder finds the other computers of the same tailnet user that run the daemon, by asking each online Mac and Windows peer's
// /status. Only same-user peers are probed, so nothing is sent to other people's devices.
type Finder struct {
	StatusJSON func() []byte
	Probe      Probe
	MyName     func() string
	MyVersion  string
	Now        func() time.Time

	mu    sync.Mutex
	cache *struct {
		until time.Time
		value []Computer
	}
}

// Computers implements Discovery, cached for 20 seconds.
func (f *Finder) Computers() []Computer {
	now := time.Now
	if f.Now != nil {
		now = f.Now
	}
	f.mu.Lock()
	if f.cache != nil && f.cache.until.After(now()) {
		v := f.cache.value
		f.mu.Unlock()
		return v
	}
	f.mu.Unlock()
	data := f.StatusJSON()
	if data == nil {
		return []Computer{}
	}
	me, peers, ok := ParseStatus(data)
	if !ok {
		return []Computer{}
	}
	var candidates []Node
	for _, p := range peers {
		if p.Online && p.UserID == me.UserID && RunsDaemon(p.OS) {
			candidates = append(candidates, p)
		}
	}
	found := make([]*Computer, len(candidates))
	var wg sync.WaitGroup
	for i, n := range candidates {
		wg.Add(1)
		go func(i int, n Node) {
			defer wg.Done()
			if s := f.Probe(n); s != nil {
				found[i] = &Computer{Name: s.Name, Address: n.DNSName, Version: s.Version}
			}
		}(i, n)
	}
	wg.Wait()
	all := []Computer{{Name: f.MyName(), Address: me.DNSName, Version: f.MyVersion, Self: true}}
	for _, c := range found {
		if c != nil {
			all = append(all, *c)
		}
	}
	f.mu.Lock()
	f.cache = &struct {
		until time.Time
		value []Computer
	}{now().Add(20 * time.Second), all}
	f.mu.Unlock()
	return all
}

// HTTPProbe asks a node's daemon for GET /status over the tailnet with a short timeout. It sends no X-Greenfield-App header, so the
// version rule does not apply to the probe.
func HTTPProbe(port int, timeout time.Duration) Probe {
	client := &http.Client{Timeout: timeout}
	return func(n Node) *Snapshot {
		resp, err := client.Get(fmt.Sprintf("http://%s/status", net.JoinHostPort(n.IP, fmt.Sprint(port))))
		if err != nil {
			return nil
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return nil
		}
		var o struct {
			OK      bool   `json:"ok"`
			Name    string `json:"name"`
			Version string `json:"version"`
		}
		if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&o) != nil || !o.OK || o.Version == "" {
			return nil
		}
		return &Snapshot{Name: o.Name, Version: o.Version}
	}
}

// AddLink is the greenfield://add link a phone can scan or tap to add this computer with no typing. Spaces and the characters that
// would end a query value are percent-encoded exactly as the Mac daemon does.
func AddLink(name, address string) string {
	return "greenfield://add?name=" + queryValue(name) + "&address=" + queryValue(address)
}

// ParseAddLink reads a link made by AddLink.
func ParseAddLink(link string) (name, address string, ok bool) {
	u, err := url.Parse(link)
	if err != nil || u.Scheme != "greenfield" || u.Host != "add" {
		return "", "", false
	}
	q := u.Query()
	if q.Get("address") == "" {
		return "", "", false
	}
	return q.Get("name"), q.Get("address"), true
}

func queryValue(s string) string {
	const allowed = "-._~!$'()*,/:;?@"
	var b strings.Builder
	for _, c := range []byte(s) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', strings.IndexByte(allowed, c) >= 0:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
