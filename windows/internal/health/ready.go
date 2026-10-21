package health

import (
	"fmt"
	"strings"
)

// Failed is true when any check failed (warnings and skips do not count).
func Failed(checks []Check) bool {
	for _, c := range checks {
		if c.Status == Fail {
			return true
		}
	}
	return false
}

// Render prints the checks. verbose adds why and fix under each failed or warned check (doctor).
func Render(checks []Check, verbose bool) string {
	var b strings.Builder
	for _, c := range checks {
		mark := map[Status]string{Pass: "✓", Fail: "✗", Warn: "!", Skip: "-"}[c.Status]
		fmt.Fprintf(&b, "%s %s: %s\n", mark, c.Title, c.Detail)
		if verbose && (c.Status == Fail || c.Status == Warn) {
			if c.Why != "" {
				fmt.Fprintf(&b, "    why: %s\n", c.Why)
			}
			if c.Fix != "" {
				fmt.Fprintf(&b, "    fix: %s\n", c.Fix)
			}
		}
	}
	return b.String()
}

// Readiness is either everything that matters is fine, or exactly one next step.
type Readiness struct {
	Ready bool
	Notes []string
	Step  string
}

// Checks fixed first, in the order a person would fix them.
var priority = []string{"daemon", "tailscale-cli", "tailnet", "auth", "listening", "firewall", "input", "can-insert"}

// Passing conditions of a healthy daemon: reported as notes, never as the thing to do next.
var transient = map[string]bool{"unlocked": true, "secure-input": true}

// Ready says "ready", or the one next step in plain words.
func Ready(checks []Check) Readiness {
	byID := map[string]Check{}
	for _, c := range checks {
		byID[c.ID] = c
	}
	step := func(c Check) Readiness {
		s := c.Fix
		if s == "" {
			s = c.Detail
		}
		return Readiness{Step: s}
	}
	for _, id := range priority {
		if c, ok := byID[id]; ok && c.Status == Fail {
			return step(c)
		}
	}
	for _, c := range checks {
		if c.Status == Fail && !transient[c.ID] {
			return step(c)
		}
	}
	r := Readiness{Ready: true}
	if byID["unlocked"].Status == Fail {
		r.Notes = append(r.Notes, "the screen is locked right now; text waits until you unlock it")
	}
	if byID["secure-input"].Status == Fail {
		r.Notes = append(r.Notes, "a password box has the keyboard right now; text waits until you leave it")
	}
	if c, ok := byID["app-compatible"]; ok && c.Status == Warn {
		r.Notes = append(r.Notes, c.Detail)
	}
	return r
}
