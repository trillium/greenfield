package winsys

import (
	"runtime"
	"strings"
	"testing"
)

func TestFirewallCommandAllowsOnlyTheTailnetToOnePort(t *testing.T) {
	got := FirewallCommandLine(FirewallAddArgs(47821))
	want := `netsh advfirewall firewall add rule name="Greenfield inserter (TCP 47821)" dir=in action=allow protocol=TCP localport=47821 remoteip=100.64.0.0/10 profile=any enable=yes`
	if got != want {
		t.Errorf("\n got %s\nwant %s", got, want)
	}
	for _, bad := range []string{"remoteip=any", "remoteip=0.0.0.0", "program="} {
		if strings.Contains(got, bad) {
			t.Errorf("the rule must not contain %s", bad)
		}
	}
	if !strings.Contains(FirewallCommandLine(FirewallDeleteArgs(5000)), `name="Greenfield inserter (TCP 5000)"`) {
		t.Errorf("each port has its own rule")
	}
}

func TestRulePresentOffWindowsIsUnknownNotMissing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("netsh exists here")
	}
	if present, known := RulePresent(47821); present || known {
		t.Errorf("without netsh the answer is \"cannot ask\", got present=%v known=%v", present, known)
	}
}
