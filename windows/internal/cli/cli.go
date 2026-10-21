// Package cli is greenfield-inserter's command line: serve (the daemon), and the commands a person runs next to it (health, doctor,
// ready, selftest, logs, name, link, firewall, port, version). Everything the commands touch is in Deps, so they are tested with
// fakes on any system.
package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"time"

	"greenfield-inserter/internal/buildinfo"
	"greenfield-inserter/internal/config"
	"greenfield-inserter/internal/health"
	"greenfield-inserter/internal/selftest"
	"greenfield-inserter/internal/state"
	"greenfield-inserter/internal/tailnet"
	"greenfield-inserter/internal/winsys"
)

// Deps are the seams of the commands. Zero values are the real thing; tests replace what they need.
type Deps struct {
	Out, Err io.Writer
	Getenv   func(string) string
	Cwd      string
	OS       string
	Paths    state.Paths
	Now      func() time.Time

	// Health asks the running daemon (GET /health on loopback).
	Health func(port int) health.Outcome
	// HostInfo is what doctor reads off the computer.
	HostInfo func(port int) health.Host
	// SelfField is the window the selftest types into.
	SelfField func() selftest.Field
	// StatusJSON is `tailscale status --json` (for the add-link).
	StatusJSON func() []byte
	// Netsh runs the firewall changes.
	AddRule, DeleteRule func(port int) (string, error)
	// Serve runs the daemon until ctx ends.
	Serve func(ctx context.Context, o ServeOptions) error
	// Elevated says whether this program runs as administrator.
	Elevated func() bool
	// Local asks this computer's own daemon on loopback, for `pair`: it is the person at this computer asking, so no key and no token.
	Local func(port int, method, path string, body map[string]any) (status int, answer map[string]any, err error)
	// FocusWait is how long the selftest window gets to take the keyboard focus (5 seconds by default).
	FocusWait time.Duration
}

// ServeOptions are the flags of serve.
type ServeOptions struct {
	Port      int
	Bind      string
	Name      string
	LogStderr bool
	NoBonjour bool
	// NoAdminCheck stops the daemon from refusing text when it thinks the app in front runs as administrator.
	NoAdminCheck bool
	DryRun       bool
	Paths        state.Paths
	Out          io.Writer
}

func (d *Deps) fill() {
	if d.Out == nil {
		d.Out = os.Stdout
	}
	if d.Err == nil {
		d.Err = os.Stderr
	}
	if d.Getenv == nil {
		d.Getenv = os.Getenv
	}
	if d.Cwd == "" {
		d.Cwd, _ = os.Getwd()
	}
	if d.OS == "" {
		d.OS = runtime.GOOS
	}
	if d.Paths.Dir == "" {
		d.Paths = state.Standard()
	}
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Health == nil {
		d.Health = func(port int) health.Outcome { return health.Fetch(port, 3*time.Second) }
	}
	if d.HostInfo == nil {
		d.HostInfo = func(port int) health.Host {
			present, known := winsys.RulePresent(port)
			return health.Host{TailscaleTool: tailnet.FindTool(), FirewallKnown: known, FirewallRule: present, Elevated: winsys.IsElevated(), OS: runtime.GOOS}
		}
	}
	if d.SelfField == nil {
		d.SelfField = func() selftest.Field { return &winsys.TestField{} }
	}
	if d.StatusJSON == nil {
		d.StatusJSON = func() []byte { return tailnet.NewCLI().StatusData() }
	}
	if d.AddRule == nil {
		d.AddRule = winsys.AddRule
	}
	if d.DeleteRule == nil {
		d.DeleteRule = winsys.DeleteRule
	}
	if d.Serve == nil {
		d.Serve = serve
	}
	if d.Elevated == nil {
		d.Elevated = winsys.IsElevated
	}
	if d.Local == nil {
		d.Local = localCall
	}
	if d.FocusWait == 0 {
		d.FocusWait = 5 * time.Second
	}
}

const usage = `greenfield-inserter (Windows): receives text from the phone over the tailnet and types it at the cursor of the focused app.

  serve [--port N] [--bind ADDR] [--name NAME] [--log-stderr] [--no-bonjour] [--no-admin-check] [--dry-run]
                     run the daemon (leave the terminal open); --dry-run types nothing, for testing the connection
  health             fast yes/no for this computer; exit 0 only if everything is good
  doctor             for each failed check: what is wrong, why it matters, the exact fix; then the live test
  ready              "ready", or exactly one next step in plain words
  selftest           open a small window and type into it through the daemon, to prove text arrives (do not type while it runs)
  link               the greenfield://add link that adds this computer to the phone with no typing
  firewall [add|remove]
                     show, add or remove the one Windows Firewall rule that lets the tailnet reach the daemon (add/remove need an administrator terminal)
  pair [--list | --revoke ID | --revoke-all]
                     a one-time code for a browser (the PWA) outside the tailnet; list or revoke paired devices
  logs [--tail N] [--since 30m]
                     the daemon's recent log, redacted (also with the daemon stopped)
  name [set NAME|reset]
                     the name the phone shows (the computer's name by default)
  port               the port in use (--port, GREENFIELD_PORT, .env, else the default)
  version            this build
  assist, permissions
                     not applicable on Windows (the window switcher and trackpad are not supported; there is nothing to approve)

The port comes from --port, then GREENFIELD_PORT, then the nearest .env, then the default in .env.example.
`

// Main runs one command and returns the exit code.
func Main(args []string, d Deps) int {
	d.fill()
	cmd := "serve"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "-h", "--help", "help":
		fmt.Fprint(d.Out, usage)
		return 0
	case "version", "--version", "-v":
		fmt.Fprintf(d.Out, "greenfield-inserter %s (commit %s) %s/%s\n", buildinfo.FullVersion(), buildinfo.Commit, runtime.GOOS, runtime.GOARCH)
		return 0
	case "port":
		port, code := d.port(args)
		if code != 0 {
			return code
		}
		fmt.Fprintln(d.Out, port)
		return 0
	case "serve":
		return d.serve(args)
	case "health":
		return d.health(args, false)
	case "doctor":
		return d.health(args, true)
	case "ready", "setup":
		return d.ready(args)
	case "selftest":
		return d.selftest(args)
	case "pair":
		return d.pair(args)
	case "logs":
		return d.logs(args)
	case "name":
		return d.name(args)
	case "link":
		return d.link(args)
	case "firewall":
		return d.firewall(args)
	case "assist":
		fmt.Fprintln(d.Out, "The assist tools (window switcher and trackpad) are not supported on Windows. The phone hides them for this computer.")
		return 0
	case "permissions":
		fmt.Fprintln(d.Out, "Nothing to approve: Windows has no Accessibility permission. If typing is dropped, the app in front probably runs as administrator (run `greenfield-inserter doctor`).")
		return 0
	default:
		fmt.Fprintf(d.Err, "unknown command %q\n\n%s", cmd, usage)
		return 2
	}
}

// option reads `--name value` and `--name=value`.
func option(name string, args []string) (string, bool, error) {
	for i, a := range args {
		if a == name {
			if i+1 >= len(args) {
				return "", false, fmt.Errorf("%s needs a value", name)
			}
			return args[i+1], true, nil
		}
		if strings.HasPrefix(a, name+"=") {
			return strings.TrimPrefix(a, name+"="), true, nil
		}
	}
	return "", false, nil
}

func has(flag string, args []string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func (d *Deps) port(args []string) (int, int) {
	flag, _, err := option("--port", args)
	if err != nil {
		fmt.Fprintln(d.Err, err)
		return 0, 2
	}
	env := map[string]string{config.PortVariable: d.Getenv(config.PortVariable)}
	n, err := config.Port(flag, env, config.LoadDotEnv(d.Cwd))
	if err != nil {
		fmt.Fprintln(d.Err, err)
		return 0, 2
	}
	return n, 0
}

func (d *Deps) serve(args []string) int {
	port, code := d.port(args)
	if code != 0 {
		return code
	}
	o := ServeOptions{Port: port, Paths: d.Paths, Out: d.Out, LogStderr: has("--log-stderr", args), NoBonjour: has("--no-bonjour", args), NoAdminCheck: has("--no-admin-check", args), DryRun: has("--dry-run", args)}
	var err error
	if o.Bind, _, err = option("--bind", args); err == nil {
		o.Name, _, err = option("--name", args)
	}
	if err != nil {
		fmt.Fprintln(d.Err, err)
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := d.Serve(ctx, o); err != nil {
		fmt.Fprintln(d.Err, "error:", err)
		return 1
	}
	return 0
}
