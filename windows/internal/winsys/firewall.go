package winsys

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// TailnetRange is what the firewall rule lets in: Tailscale's own address range, and nothing else.
const TailnetRange = "100.64.0.0/10"

// RuleName is the one inbound rule the daemon needs. It names the port so a second daemon on another port has its own.
func RuleName(port int) string { return "Greenfield inserter (TCP " + strconv.Itoa(port) + ")" }

// FirewallAddArgs is the netsh command that allows the tailnet to reach the daemon's port. It needs an administrator terminal.
func FirewallAddArgs(port int) []string {
	return []string{"advfirewall", "firewall", "add", "rule", "name=" + RuleName(port), "dir=in", "action=allow", "protocol=TCP",
		"localport=" + strconv.Itoa(port), "remoteip=" + TailnetRange, "profile=any", "enable=yes"}
}

// FirewallDeleteArgs removes that rule.
func FirewallDeleteArgs(port int) []string {
	return []string{"advfirewall", "firewall", "delete", "rule", "name=" + RuleName(port)}
}

// FirewallShowArgs reads that rule.
func FirewallShowArgs(port int) []string {
	return []string{"advfirewall", "firewall", "show", "rule", "name=" + RuleName(port)}
}

// FirewallCommandLine is the command as a person would type it.
func FirewallCommandLine(args []string) string {
	parts := []string{"netsh"}
	for _, a := range args {
		if strings.ContainsAny(a, " ()") {
			if k, v, ok := strings.Cut(a, "="); ok {
				a = k + `="` + v + `"`
			}
		}
		parts = append(parts, a)
	}
	return strings.Join(parts, " ")
}

// RulePresent asks the firewall whether the rule exists. known is false when netsh could not be run at all (not Windows, or no
// permission to ask). netsh answers exit code 0 for a rule that exists and 1 for "no rules match" in every language, and the rule
// output names the port, which is checked too.
func RulePresent(port int) (present, known bool) {
	out, err := runNetsh(FirewallShowArgs(port))
	if err == nil {
		return strings.Contains(out, strconv.Itoa(port)), true
	}
	if _, isExit := err.(*exec.ExitError); isExit {
		return false, true
	}
	return false, false
}

func runNetsh(args []string) (string, error) {
	cmd := exec.Command("netsh", args...)
	done := make(chan struct{})
	var out []byte
	var err error
	go func() { out, err = cmd.CombinedOutput(); close(done) }()
	select {
	case <-done:
		return string(out), err
	case <-time.After(10 * time.Second):
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		return "", fmt.Errorf("netsh did not answer within 10 seconds")
	}
}

// AddRule adds the inbound rule (needs an administrator terminal) and returns netsh's own words.
func AddRule(port int) (string, error) { return runNetsh(FirewallAddArgs(port)) }

// DeleteRule removes the rule.
func DeleteRule(port int) (string, error) { return runNetsh(FirewallDeleteArgs(port)) }
