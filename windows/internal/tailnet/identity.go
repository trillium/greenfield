// Package tailnet asks the local Tailscale who owns an address, which is the whole trust boundary of the daemon: a caller is
// accepted when its device belongs to the same tailnet user as this computer's own node. Nothing is configured and no key exists.
package tailnet

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Kind is who a tailnet address belongs to, relative to this computer's own node.
type Kind int

const (
	// SameUser: the same tailnet user as this computer's own node.
	SameUser Kind = iota
	// OtherUser: a device of someone else, or a tagged (non-user) device.
	OtherUser
	// Unknown: Tailscale could not say. Callers must treat this as "deny".
	Unknown
)

// Peer is the answer to "who owns this address".
type Peer struct {
	Kind  Kind
	Login string // SameUser/OtherUser: the login name
	Why   string // Unknown: what went wrong, in words
}

// Identity is what the server needs from Tailscale.
type Identity interface {
	// Identify asks the local Tailscale who owns address and compares with this computer's own user.
	Identify(address string) Peer
	// SelfLogin is the login name of this computer's own tailnet user, "" if Tailscale cannot say.
	SelfLogin() string
}

// Whois is the part of `tailscale whois --json` that matters.
type Whois struct {
	UserID int64
	Login  string
	Tagged bool
}

// ParseWhois reads `tailscale whois --json` output.
func ParseWhois(data []byte) (Whois, bool) {
	var o struct {
		Node struct {
			User json.Number `json:"User"`
			Tags []string    `json:"Tags"`
		} `json:"Node"`
		UserProfile struct {
			LoginName string `json:"LoginName"`
		} `json:"UserProfile"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&o); err != nil || o.Node.User == "" {
		return Whois{}, false
	}
	id, err := o.Node.User.Int64()
	if err != nil {
		return Whois{}, false
	}
	login := o.UserProfile.LoginName
	if login == "" {
		login = fmt.Sprintf("user %d", id)
	}
	return Whois{UserID: id, Login: login, Tagged: len(o.Node.Tags) > 0}, true
}

// Compare decides what the peer is relative to me. A tagged device is owned by the tailnet, not by a person, so it never counts as
// "the same user".
func Compare(peer, me Whois) Peer {
	if peer.Tagged || me.Tagged {
		login := peer.Login
		if peer.Tagged {
			login = "a tagged device"
		}
		return Peer{Kind: OtherUser, Login: login}
	}
	if peer.UserID == me.UserID {
		return Peer{Kind: SameUser, Login: peer.Login}
	}
	return Peer{Kind: OtherUser, Login: peer.Login}
}

// Runner runs the tailscale command-line tool. ok is false when the tool is missing or did not answer.
type Runner func(args ...string) (status int, output []byte, stderr string, ok bool)

// CLI talks to the local Tailscale through its command-line tool, which knows how to reach the local API however Tailscale was
// installed. Results are cached briefly; failures are cached even more briefly so a restarting Tailscale recovers quickly but a
// burst of requests does not start a storm of processes.
type CLI struct {
	run        Runner
	ownAddress func() string
	now        func() time.Time

	mu     sync.Mutex
	cache  map[string]cached
	status struct {
		until time.Time
		data  []byte
	}
}

type cached struct {
	until  time.Time
	record *Whois
	reason string
}

// NewCLI uses the real tailscale tool and this computer's real tailnet address.
func NewCLI() *CLI { return NewCLIWith(RunTool, IPv4, time.Now) }

// NewCLIWith lets tests supply the tool, the own address and the clock.
func NewCLIWith(run Runner, own func() string, now func() time.Time) *CLI {
	return &CLI{run: run, ownAddress: own, now: now, cache: map[string]cached{}}
}

// Candidates are the places the tailscale tool is looked for after PATH.
func Candidates() []string {
	switch runtime.GOOS {
	case "windows":
		var out []string
		for _, env := range []string{"ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"} {
			if dir := os.Getenv(env); dir != "" {
				out = append(out, filepath.Join(dir, "Tailscale", "tailscale.exe"))
			}
		}
		return append(out, `C:\Program Files\Tailscale\tailscale.exe`, `C:\Program Files (x86)\Tailscale\tailscale.exe`)
	case "darwin":
		return []string{"/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"}
	default:
		return []string{"/usr/bin/tailscale", "/usr/local/bin/tailscale"}
	}
}

// FindTool returns the path of the tailscale command-line tool, or "".
func FindTool() string {
	if p, err := exec.LookPath("tailscale"); err == nil {
		return p
	}
	for _, c := range Candidates() {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	return ""
}

// RunTool runs the real tailscale tool with a 4 second limit.
func RunTool(args ...string) (int, []byte, string, bool) {
	path := FindTool()
	if path == "" {
		return 0, nil, "", false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, args...)
	hideWindow(cmd)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if ctx.Err() != nil {
		return -1, nil, path + " did not answer within 4 seconds", true
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode(), out.Bytes(), errb.String(), true
		}
		return -1, nil, "could not start " + path + ": " + err.Error(), true
	}
	return 0, out.Bytes(), errb.String(), true
}

func (c *CLI) whois(address string) (*Whois, string) {
	c.mu.Lock()
	if hit, ok := c.cache[address]; ok && hit.until.After(c.now()) {
		c.mu.Unlock()
		return hit.record, hit.reason
	}
	c.mu.Unlock()

	var record *Whois
	reason := ""
	if status, out, stderr, ok := c.run("whois", "--json", address); ok {
		if w, parsed := ParseWhois(out); status == 0 && parsed {
			record = &w
		} else {
			detail := strings.TrimSpace(stderr)
			if len(detail) > 160 {
				detail = detail[:160]
			}
			if detail != "" {
				detail = ": " + detail
			}
			reason = fmt.Sprintf("tailscale could not identify %s (exit %d%s)", address, status, detail)
		}
	} else {
		reason = "the tailscale command-line tool is missing or did not answer"
	}
	ttl := 3 * time.Second
	if record != nil {
		ttl = 60 * time.Second
	}
	c.mu.Lock()
	c.cache[address] = cached{until: c.now().Add(ttl), record: record, reason: reason}
	c.mu.Unlock()
	return record, reason
}

// StatusData is `tailscale status --json`, cached for a few seconds. nil when it cannot be read.
func (c *CLI) StatusData() []byte {
	c.mu.Lock()
	if c.status.until.After(c.now()) {
		d := c.status.data
		c.mu.Unlock()
		return d
	}
	c.mu.Unlock()
	status, out, _, ok := c.run("status", "--json")
	if !ok || status != 0 || len(out) == 0 {
		return nil
	}
	c.mu.Lock()
	c.status.until, c.status.data = c.now().Add(10*time.Second), out
	c.mu.Unlock()
	return out
}

// SelfLogin implements Identity.
func (c *CLI) SelfLogin() string {
	own := c.ownAddress()
	if own == "" {
		return ""
	}
	if w, _ := c.whois(own); w != nil {
		return w.Login
	}
	return ""
}

// Identify implements Identity.
func (c *CLI) Identify(address string) Peer {
	own := c.ownAddress()
	if own == "" {
		return Peer{Kind: Unknown, Why: "this computer has no tailnet address"}
	}
	me, why := c.whois(own)
	if me == nil {
		return Peer{Kind: Unknown, Why: why}
	}
	them, why := c.whois(address)
	if them == nil {
		return Peer{Kind: Unknown, Why: why}
	}
	return Compare(*them, *me)
}

// IPv4 is this computer's tailnet address: an IPv4 address in the CGNAT range 100.64.0.0/10 that Tailscale assigns. Binding only
// to it (and loopback) keeps the daemon off the LAN. "" when there is none.
func IPv4() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && InTailnetRange(ipn.IP) {
			return ipn.IP.To4().String()
		}
	}
	return ""
}

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// InTailnetRange says whether ip is in 100.64.0.0/10.
func InTailnetRange(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && cgnat.Contains(v4)
}
