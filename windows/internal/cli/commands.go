package cli

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"greenfield-inserter/internal/health"
	"greenfield-inserter/internal/logsvc"
	"greenfield-inserter/internal/selftest"
	"greenfield-inserter/internal/state"
	"greenfield-inserter/internal/tailnet"
	"greenfield-inserter/internal/winsys"
)

func (d *Deps) health(args []string, doctor bool) int {
	port, code := d.port(args)
	if code != 0 {
		return code
	}
	outcome := d.Health(port)
	var host *health.Host
	if doctor {
		h := d.HostInfo(port)
		host = &h
	}
	checks := health.Checks(outcome, port, host)
	fmt.Fprint(d.Out, health.Render(checks, doctor))
	failed := health.Failed(checks)
	if !doctor {
		if failed {
			fmt.Fprintln(d.Out, "\nNot healthy. Run `greenfield-inserter doctor` for what to do.")
			return 1
		}
		fmt.Fprintln(d.Out, "\nHealthy.")
		return 0
	}
	// doctor: when everything else is fine, run the live test for the one thing left, as the Mac's doctor does.
	onlyProof := failed
	for _, c := range checks {
		if c.Status == health.Fail && c.ID != "can-insert" && c.ID != "input" {
			onlyProof = false
		}
	}
	if failed && onlyProof && !has("--no-selftest", args) {
		fmt.Fprintln(d.Out, "\nEverything else is fine; running the live test (a small window opens for a few seconds; do not type).")
		return d.runSelftest(port, checks)
	}
	if failed {
		return 1
	}
	fmt.Fprintln(d.Out, "\nAll good.")
	return 0
}

func (d *Deps) ready(args []string) int {
	port, code := d.port(args)
	if code != 0 {
		return code
	}
	h := d.HostInfo(port)
	r := health.Ready(health.Checks(d.Health(port), port, &h))
	if r.Ready {
		fmt.Fprintln(d.Out, "ready")
		for _, n := range r.Notes {
			fmt.Fprintln(d.Out, "  note:", n)
		}
		return 0
	}
	fmt.Fprintln(d.Out, "not ready. Next step:", r.Step)
	return 1
}

func (d *Deps) selftest(args []string) int {
	port, code := d.port(args)
	if code != 0 {
		return code
	}
	return d.runSelftest(port, health.Checks(d.Health(port), port, nil))
}

func (d *Deps) runSelftest(port int, checks []health.Check) int {
	ledger := &state.DeliveryLedger{File: d.Paths.DeliveryFile(), DaemonStart: time.Time{}, Now: d.Now}
	n := 0
	res := selftest.Run(checks, d.SelfField(), selftest.Loopback{Port: port, Timeout: 10 * time.Second}, ledger, func() string {
		n++
		return strconv.FormatInt(d.Now().UnixNano(), 36) + strconv.Itoa(n)
	}, d.FocusWait)
	fmt.Fprint(d.Out, res.Text())
	if res.Pass {
		return 0
	}
	return 1
}

func (d *Deps) logs(args []string) int {
	var parts []string
	for _, name := range []string{"--tail", "--since"} {
		v, ok, err := option(name, args)
		if err != nil {
			fmt.Fprintln(d.Err, err)
			return 2
		}
		if ok {
			parts = append(parts, strings.TrimPrefix(name, "--")+"="+v)
		}
	}
	q, err := logsvc.ParseQuery(strings.Join(parts, "&"))
	if err != nil {
		fmt.Fprintln(d.Err, err)
		return 2
	}
	src := logsvc.NewFileSource(d.Paths.LogFile())
	if !src.Available() {
		fmt.Fprintln(d.Err, "no log yet:", d.Paths.LogFile(), "(the daemon creates it when it starts)")
		return 1
	}
	for _, l := range logsvc.BuildPage(src.Read(q, d.Now()), q).Lines {
		fmt.Fprintln(d.Out, l)
	}
	return 0
}

func (d *Deps) names() state.NameStore { return state.NameStore{File: d.Paths.NameFile()} }

func (d *Deps) name(args []string) int {
	switch {
	case len(args) == 0:
		fmt.Fprintln(d.Out, d.names().Current())
	case args[0] == "set" && len(args) > 1:
		if err := d.names().Set(strings.Join(args[1:], " ")); err != nil {
			fmt.Fprintln(d.Err, "error: could not save the name:", err)
			return 1
		}
		fmt.Fprintln(d.Out, d.names().Current())
	case args[0] == "reset":
		if err := d.names().Clear(); err != nil {
			fmt.Fprintln(d.Err, "error:", err)
			return 1
		}
		fmt.Fprintln(d.Out, d.names().Current())
	default:
		fmt.Fprintln(d.Err, "usage: name [set NAME | reset]")
		return 2
	}
	return 0
}

func (d *Deps) link(args []string) int {
	data := d.StatusJSON()
	me, _, ok := tailnet.ParseStatus(data)
	if !ok {
		fmt.Fprintln(d.Err, "Tailscale does not say who this computer is (is it running and signed in?). Open Tailscale, then run this again.")
		return 1
	}
	fmt.Fprintln(d.Out, "Add this computer to the phone (open this link on the phone, or paste it into Computers > Add):")
	fmt.Fprintln(d.Out, tailnet.AddLink(d.names().Current(), me.DNSName))
	if !has("--no-qr", args) {
		fmt.Fprintln(d.Out, "(No QR code on Windows yet. The phone also finds this computer by itself over the tailnet and on the local network.)")
	}
	return 0
}

func (d *Deps) firewall(args []string) int {
	port, code := d.port(args)
	if code != 0 {
		return code
	}
	sub := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		sub = args[0]
	}
	switch sub {
	case "":
		fmt.Fprintln(d.Out, "Windows Firewall blocks inbound connections until a rule allows them. This one rule lets the tailnet (100.64.0.0/10) reach TCP port", port, "and nothing else:")
		fmt.Fprintln(d.Out, "  "+winsys.FirewallCommandLine(winsys.FirewallAddArgs(port)))
		fmt.Fprintln(d.Out, "Run it in a terminal opened as administrator, or let this program do it: `greenfield-inserter firewall add`.")
		return 0
	case "add", "remove":
		if !d.Elevated() {
			fmt.Fprintln(d.Err, "This changes the firewall, so it needs a terminal opened as administrator (right-click the terminal, Run as administrator).")
			return 1
		}
		fn := d.AddRule
		if sub == "remove" {
			fn = d.DeleteRule
		}
		out, err := fn(port)
		fmt.Fprint(d.Out, out)
		if err != nil {
			fmt.Fprintln(d.Err, "error:", err)
			return 1
		}
		fmt.Fprintln(d.Out, "done")
		return 0
	default:
		fmt.Fprintln(d.Err, "usage: firewall [add | remove]")
		return 2
	}
}
