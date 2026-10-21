package health

import (
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"greenfield-inserter/internal/compat"
	"greenfield-inserter/internal/state"
)

func titleFor(id string) string {
	return map[string]string{
		"listening": "Listening on tailnet and loopback only", "auth": "Authorization by tailnet identity", "input": "Windows lets this program type",
		"unlocked": "Screen not locked", "secure-input": "No password field has the keyboard", "version": "Version", "can-insert": "Can actually insert text",
		"app-compatible": "App compatible", "logs": "Logs available", "tailnet": "Connected to the tailnet", "tailscale-cli": "Tailscale command-line tool found",
		"firewall": "Windows Firewall lets the tailnet in",
	}[id]
}

const exe = "greenfield-inserter.exe"

// Checks turns what the daemon says (and, for doctor, what the computer says) into the list of checks.
func Checks(o Outcome, port int, host *Host) []Check {
	var checks []Check
	if host != nil {
		checks = append(checks, hostChecks(host, port, o.Snapshot)...)
	}
	if o.Unreachable != "" {
		checks = append(checks, Check{ID: "daemon", Title: "Daemon running", Status: Fail,
			Detail: fmt.Sprintf("no answer from 127.0.0.1:%d (%s)", port, o.Unreachable),
			Why:    "Nothing on this computer is accepting text, so everything the phone sends is lost.",
			Fix:    "Start it: open a terminal and run `" + exe + " serve` (leave it open). If it says the port is busy, set GREENFIELD_PORT in .env or pass --port."})
		for _, id := range []string{"listening", "auth", "input", "unlocked", "secure-input", "version", "app-compatible", "can-insert"} {
			checks = append(checks, Check{ID: id, Title: titleFor(id), Status: Skip, Detail: "not checked: daemon not reachable"})
		}
		return checks
	}
	if o.Snapshot == nil {
		checks = append(checks, Check{ID: "daemon", Title: "Daemon running", Status: Fail,
			Detail: fmt.Sprintf("something answered on port %d with HTTP %d but it is not greenfield-inserter", port, o.HTTP),
			Why:    "Another program may be using the port, or the daemon is a different version.",
			Fix:    "Run `" + exe + " port` to see the port in use; set GREENFIELD_PORT to a free one in .env and restart both the daemon and the phone's computer entry."})
		return checks
	}
	s := o.Snapshot
	detail := "answering on 127.0.0.1:" + strconv.Itoa(port)
	if s.PID != 0 {
		detail += " (pid " + strconv.Itoa(s.PID) + ")"
	}
	checks = append(checks, Check{ID: "daemon", Title: "Daemon running", Status: Pass, Detail: detail})
	return append(checks, snapshotChecks(s, port)...)
}

func hostChecks(h *Host, port int, s *Snapshot) []Check {
	var out []Check
	if h.TailscaleTool == "" {
		out = append(out, Check{ID: "tailscale-cli", Title: titleFor("tailscale-cli"), Status: Fail, Detail: "tailscale.exe was not found",
			Why: "The daemon decides who may send text by asking Tailscale who owns the caller's address. Without the tool it cannot, and refuses everyone (HTTP 503).",
			Fix: "Install Tailscale for Windows (tailscale.com/download) and sign in, or add its folder (C:\\Program Files\\Tailscale) to PATH."})
	} else {
		out = append(out, Check{ID: "tailscale-cli", Title: titleFor("tailscale-cli"), Status: Pass, Detail: h.TailscaleTool})
	}
	if h.OS != "windows" {
		return out
	}
	switch {
	case !h.FirewallKnown:
		out = append(out, Check{ID: "firewall", Title: titleFor("firewall"), Status: Warn, Detail: "could not read the firewall rules",
			Why: "Windows Firewall blocks inbound connections to a program until a rule allows them; Tailscale's network is usually classed as public, so without a rule the phone cannot connect.",
			Fix: "Run `" + exe + " firewall` to see the one rule to add, and `" + exe + " firewall add` from an administrator terminal to add it."})
	case !h.FirewallRule && s != nil && s.AppCompatible != nil && !strings.HasPrefix(s.AppCompatible.Message, "no app has connected"):
		// Windows also offers its own "allow this program" prompt, which makes a rule of its own: an app has got through, so it works.
		out = append(out, Check{ID: "firewall", Title: titleFor("firewall"), Status: Warn, Detail: "no rule named for this daemon, but an app has connected, so something allows it",
			Why: "A rule made by Windows' own prompt may cover only some network profiles, and Tailscale's network can change profile.",
			Fix: "Optional: `" + exe + " firewall add` from an administrator terminal makes one rule that always covers the tailnet."})
	case !h.FirewallRule:
		out = append(out, Check{ID: "firewall", Title: titleFor("firewall"), Status: Fail, Detail: "no inbound rule for TCP port " + strconv.Itoa(port) + " from the tailnet",
			Why: "Windows Firewall drops inbound connections to a program until a rule allows them, so the phone would time out although the daemon is running.",
			Fix: "From a terminal opened as administrator: `" + exe + " firewall add` (it allows TCP port " + strconv.Itoa(port) + " from 100.64.0.0/10, the tailnet range, only)."})
	default:
		out = append(out, Check{ID: "firewall", Title: titleFor("firewall"), Status: Pass, Detail: "an inbound rule for TCP port " + strconv.Itoa(port) + " from the tailnet exists"})
	}
	return out
}

func isTailnetOrLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	v4 := ip.To4()
	return v4 != nil && v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
}

func snapshotChecks(s *Snapshot, port int) []Check {
	var out []Check
	hasLoopback, hasTailnet := false, false
	var outside []string
	for _, l := range s.Listen {
		switch {
		case strings.HasPrefix(l, "127."):
			hasLoopback = true
		case isTailnetOrLoopback(l):
			hasTailnet = true
		default:
			outside = append(outside, l)
		}
	}
	switch {
	case len(outside) > 0:
		out = append(out, Check{ID: "listening", Title: titleFor("listening"), Status: Fail, Detail: "also listening on " + strings.Join(outside, ", "),
			Why: "Plain HTTP is only acceptable because the daemon is reachable by tailnet members alone; another interface widens that.",
			Fix: "Restart it without `--bind`, so it serves the tailnet address and loopback only."})
	case hasLoopback && hasTailnet:
		out = append(out, Check{ID: "listening", Title: titleFor("listening"), Status: Pass, Detail: strings.Join(s.Listen, ", ")})
	default:
		missing := []string{}
		if !hasTailnet {
			missing = append(missing, "tailnet address")
		}
		if !hasLoopback {
			missing = append(missing, "loopback")
		}
		serving := "nothing"
		if len(s.Listen) > 0 {
			serving = strings.Join(s.Listen, ", ")
		}
		out = append(out, Check{ID: "tailnet", Title: titleFor("tailnet"), Status: Fail,
			Detail: "not listening on " + strings.Join(missing, " and ") + " (serving: " + serving + ")",
			Why:    "The phone cannot reach the daemon over the tailnet until this computer has a tailnet address.",
			Fix:    "Open Tailscale and sign in (`tailscale status`); the daemon binds by itself within a few seconds of the address appearing."})
	}
	switch {
	case s.Auth == "":
		out = append(out, Check{ID: "auth", Title: titleFor("auth"), Status: Fail, Detail: "the daemon does not say how it authorizes",
			Why: "It is not a version of greenfield-inserter that trusts the tailnet.", Fix: "Rebuild and replace " + exe + " (`make windows`)."})
	case !s.IdentityOK:
		out = append(out, Check{ID: "auth", Title: titleFor("auth"), Status: Fail, Detail: "cannot ask Tailscale who is calling",
			Why: "The daemon refuses every request it cannot attribute to a tailnet user (it fails closed), so the phone's text would be rejected (HTTP 503).",
			Fix: "Make sure Tailscale is running and signed in (`tailscale status`), and that tailscale.exe is in C:\\Program Files\\Tailscale or on PATH."})
	default:
		user := "same tailnet user as this computer"
		if s.TailnetUser != "" {
			user += " (" + s.TailnetUser + ")"
		}
		out = append(out, Check{ID: "auth", Title: titleFor("auth"), Status: Pass, Detail: user + "; no key or password exists or is needed"})
	}
	if s.InputAllowed {
		out = append(out, Check{ID: "input", Title: titleFor("input"), Status: Pass, Detail: "nothing in front blocks typing right now"})
	} else {
		out = append(out, Check{ID: "input", Title: titleFor("input"), Status: Fail, Detail: "the app in front runs as administrator",
			Why: "Windows lets a normal program type only into normal apps, and silently drops the keys otherwise, so the daemon refuses text (HTTP 503) instead of losing it.",
			Fix: "Click into a normal app (Notepad, a browser), or start greenfield-inserter from a terminal opened as administrator too."})
	}
	if s.ScreenLocked {
		out = append(out, Check{ID: "unlocked", Title: titleFor("unlocked"), Status: Fail, Detail: "the screen is locked (or a secure prompt has the screen)",
			Why: "Input cannot be delivered to the lock screen; the daemon refuses text with HTTP 423 until it is unlocked.", Fix: "Unlock this computer."})
	} else {
		out = append(out, Check{ID: "unlocked", Title: titleFor("unlocked"), Status: Pass, Detail: "unlocked"})
	}
	if s.SecureInput {
		out = append(out, Check{ID: "secure-input", Title: titleFor("secure-input"), Status: Fail, Detail: "a password box has the keyboard",
			Why: "The daemon refuses text with HTTP 409 so a dictation is never typed into a password field.", Fix: "Click out of the password box."})
	} else {
		out = append(out, Check{ID: "secure-input", Title: titleFor("secure-input"), Status: Pass, Detail: "off"})
	}
	version := Check{ID: "version", Title: titleFor("version"), Status: Pass, Detail: s.Version}
	if s.BuildCommit != "" && s.BuildCommit != "unknown" {
		version.Detail += " (commit " + s.BuildCommit + ")"
	}
	if s.Version == "0.0.0" {
		version = Check{ID: "version", Title: titleFor("version"), Status: Warn, Detail: "0.0.0: this build was not stamped with a version",
			Why: "The phone compares versions; an unstamped build is reported as \"update the computer's daemon\".", Fix: "Build with `make windows` from the repository (it stamps the version from the git tags)."}
	}
	out = append(out, version)
	if c := s.AppCompatible; c != nil {
		note := strings.HasPrefix(c.Message, "no app has connected")
		switch {
		case c.OK && note:
			out = append(out, Check{ID: "app-compatible", Title: titleFor("app-compatible"), Status: Pass, Detail: "note: " + c.Message})
		case c.OK:
			out = append(out, Check{ID: "app-compatible", Title: titleFor("app-compatible"), Status: Pass, Detail: c.Message})
		default:
			out = append(out, Check{ID: "app-compatible", Title: titleFor("app-compatible"), Status: Warn, Detail: c.Message,
				Why: "An app that is on the wrong side of the compatibility rule gets HTTP 426 and cannot send text.", Fix: c.Fix})
		}
	}
	if s.LogsAvailable {
		out = append(out, Check{ID: "logs", Title: titleFor("logs"), Status: Pass, Detail: "`" + exe + " logs --tail 100` or `make logs` shows the recent log, without text or keys"})
	} else {
		out = append(out, Check{ID: "logs", Title: titleFor("logs"), Status: Warn, Detail: "the daemon has no readable log file",
			Why: "Without its log nobody can see why something failed here without sitting at this computer.", Fix: "Restart the daemon; it creates the log when it starts."})
	}
	out = append(out, canInsertCheck(s.CanInsert))
	return out
}

func canInsertCheck(c state.CanInsert) Check {
	title := titleFor("can-insert")
	switch c.State {
	case state.StateOK:
		how := "by a real delivery"
		if c.Source == "selftest" {
			how = "by the selftest"
		}
		at := "at an unknown time"
		if c.At != nil {
			at = compat.AgeText(*c.At, time.Now())
		}
		return Check{ID: "can-insert", Title: title, Status: Pass, Detail: "text was read back from a field " + at + " " + how}
	case state.StateFailed:
		at := "earlier"
		if c.At != nil {
			at = compat.AgeText(*c.At, time.Now())
		}
		return Check{ID: "can-insert", Title: title, Status: Fail, Detail: "the last attempt " + at + " did not arrive: " + c.Detail,
			Why: "The daemon sent the keys and could see that the text did not appear, so dictation would be lost.",
			Fix: "Run `" + exe + " doctor` (it re-runs the live test). Usual cause: the app in front runs as administrator."}
	default:
		return Check{ID: "can-insert", Title: title, Status: Fail, Detail: c.Detail,
			Why: "Nothing has proven that text arrives since the daemon started, so \"inserted\" cannot be promised.",
			Fix: "Run `" + exe + " selftest` (opens a small window for a few seconds; do not type), or send one real text and `health` will pick up the confirmed delivery."}
	}
}
