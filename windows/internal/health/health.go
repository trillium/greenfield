// Package health answers "is this computer ready to take dictation?": `health` (a fast yes/no), `doctor` (what is wrong, why it
// matters, the exact fix) and `ready` (ready, or exactly one next step in plain words). It reads the running daemon's loopback-only
// GET /health, so it reports what the running process sees, not what a fresh process would.
package health

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"greenfield-inserter/internal/compat"
	"greenfield-inserter/internal/state"
)

// Status of one check.
type Status int

const (
	Pass Status = iota
	Fail
	Warn
	Skip
)

func (s Status) String() string { return [...]string{"pass", "FAIL", "warn", "skip"}[s] }

// Check is one yes/no fact about the setup. Why and Fix are only shown by doctor.
type Check struct {
	ID     string
	Title  string
	Status Status
	Detail string
	Why    string
	Fix    string
}

// Snapshot is what the running daemon says about itself.
type Snapshot struct {
	Name, Version             string
	Listen                    []string
	InputAllowed              bool
	ScreenLocked, SecureInput bool
	Auth                      string
	IdentityOK                bool
	TailnetUser               string
	CanInsert                 state.CanInsert
	MinClientVersion          string
	AppCompatible             *compat.AppCompat
	BuildCommit, BuildSHA     string
	Executable                string
	PID                       int
	LogsAvailable             bool
	Platform                  string
}

// Outcome of asking the daemon.
type Outcome struct {
	Snapshot *Snapshot
	// Unreachable: no answer at all, with the reason.
	Unreachable string
	// HTTP is the status when the daemon answered but not with a snapshot.
	HTTP int
}

// Fetch asks the daemon on loopback for GET /health.
func Fetch(port int, timeout time.Duration) Outcome {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get("http://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) + "/health")
	if err != nil {
		return Outcome{Unreachable: err.Error()}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		return Outcome{HTTP: resp.StatusCode}
	}
	s, ok := ParseSnapshot(body)
	if !ok {
		return Outcome{HTTP: resp.StatusCode}
	}
	return Outcome{Snapshot: s}
}

// ParseSnapshot reads a /health or /status answer.
func ParseSnapshot(body []byte) (*Snapshot, bool) {
	var o struct {
		Version       string                             `json:"version"`
		Name          string                             `json:"name"`
		Listen        []string                           `json:"listen"`
		Accessibility bool                               `json:"accessibility"`
		ScreenLocked  bool                               `json:"screen_locked"`
		SecureInput   bool                               `json:"secure_input"`
		Auth          string                             `json:"auth"`
		IdentityOK    bool                               `json:"identity_ok"`
		TailnetUser   string                             `json:"tailnet_user"`
		Evidence      json.RawMessage                    `json:"evidence"`
		MinClient     string                             `json:"min_client_version"`
		AppCompatible *compat.AppCompat                  `json:"app_compatible"`
		Build         struct{ Commit, BinarySHA string } `json:"-"`
		BuildRaw      struct {
			Commit    string `json:"commit"`
			BinarySHA string `json:"binary_sha"`
		} `json:"build"`
		Executable    string `json:"executable"`
		PID           int    `json:"pid"`
		LogsAvailable bool   `json:"logs_available"`
		Platform      string `json:"platform"`
	}
	if json.Unmarshal(body, &o) != nil || o.Version == "" {
		return nil, false
	}
	s := &Snapshot{
		Name: o.Name, Version: o.Version, Listen: o.Listen, InputAllowed: o.Accessibility, ScreenLocked: o.ScreenLocked, SecureInput: o.SecureInput,
		Auth: o.Auth, IdentityOK: o.IdentityOK, TailnetUser: o.TailnetUser, MinClientVersion: o.MinClient, AppCompatible: o.AppCompatible,
		BuildCommit: o.BuildRaw.Commit, BuildSHA: o.BuildRaw.BinarySHA, Executable: o.Executable, PID: o.PID, LogsAvailable: o.LogsAvailable, Platform: o.Platform,
		CanInsert: state.CanInsert{State: state.StateUnknown},
	}
	var ev struct {
		State  string `json:"state"`
		At     string `json:"at"`
		Source string `json:"source"`
		Detail string `json:"detail"`
	}
	if json.Unmarshal(o.Evidence, &ev) == nil && ev.State != "" {
		s.CanInsert = state.CanInsert{State: state.CanInsertState(ev.State), Source: ev.Source, Detail: ev.Detail}
		if t, err := time.Parse(time.RFC3339, ev.At); err == nil {
			s.CanInsert.At = &t
		}
	}
	return s, true
}

// Host is what only the computer itself can say, for doctor.
type Host struct {
	// TailscaleTool is the path of the tailscale command-line tool, "" when it is not found.
	TailscaleTool string
	// FirewallKnown is false when the firewall could not be asked; FirewallRule says whether an inbound rule for the port exists.
	FirewallKnown bool
	FirewallRule  bool
	// Elevated: this program runs as administrator.
	Elevated bool
	// OS is runtime.GOOS; the checks that are about Windows are skipped elsewhere.
	OS string
}
