package cli

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"greenfield-inserter/internal/buildinfo"
	"greenfield-inserter/internal/inserter"
	"greenfield-inserter/internal/logsvc"
	"greenfield-inserter/internal/mdns"
	"greenfield-inserter/internal/server"
	"greenfield-inserter/internal/state"
	"greenfield-inserter/internal/tailnet"
	"greenfield-inserter/internal/winsys"
)

// serve is the daemon.
func serve(ctx context.Context, o ServeOptions) error {
	if err := o.Paths.EnsureDir(); err != nil {
		return fmt.Errorf("cannot create %s: %v", o.Paths.Dir, err)
	}
	var echo func(string)
	if o.LogStderr {
		echo = func(s string) { fmt.Fprint(os.Stderr, s) }
	}
	logger := logsvc.NewLogger(o.Paths.LogFile(), echo)
	// A problem that stops the phone from connecting is also said on the console, even without --log-stderr.
	say := logger.Log
	if !o.LogStderr {
		say = func(m string) {
			logger.Log(m)
			if strings.HasPrefix(m, "cannot listen") || strings.HasPrefix(m, "no tailnet address") {
				fmt.Fprintln(os.Stderr, m)
			}
		}
	}
	names := state.NameStore{File: o.Paths.NameFile()}
	name := func() string {
		if o.Name != "" {
			return o.Name
		}
		return names.Current()
	}
	started := time.Now()
	identity := tailnet.NewCLI()
	finder := &tailnet.Finder{StatusJSON: identity.StatusData, Probe: tailnet.HTTPProbe(o.Port, 1500*time.Millisecond), MyName: name, MyVersion: buildinfo.Version}

	var ins inserter.Inserter = winsys.Inserter{}
	if o.DryRun {
		ins = dryRun{}
		logger.Log("DRY RUN: nothing will be typed")
	}
	exePath, _ := os.Executable()
	var listeners *server.Listeners
	h := server.New(server.Config{
		Probe: winsys.Probe{SkipElevationCheck: o.NoAdminCheck}, Inserter: ins, Identity: identity, Discovery: finder, Logger: logger,
		Record:  &state.DeliveryLedger{File: o.Paths.DeliveryFile(), DaemonStart: started},
		Clients: &state.ClientLedger{File: o.Paths.ClientsFile()}, LogSource: logsvc.NewFileSource(o.Paths.LogFile()),
		Name: name, Listening: func() []string { return listeners.Listening() },
		Version: buildinfo.Version, MinClient: buildinfo.MinClient,
		Build:      server.Build{Version: buildinfo.Version, Commit: buildinfo.Commit, BinarySHA: fileSHA(exePath), StartedAt: started.UTC().Format(time.RFC3339)},
		Executable: exePath,
	})
	listeners = &server.Listeners{Port: o.Port, Bind: o.Bind, Handler: h, Log: say}

	logger.Log(fmt.Sprintf("starting greenfield-inserter %s name=%s", buildinfo.FullVersion(), name()))
	logger.Log("who may call: loopback, or a device of the same tailnet user (no key, no password)")
	if winsys.IsElevated() {
		logger.Log("running as administrator")
	}
	fmt.Fprintf(o.Out, "greenfield-inserter %s serving on port %d (log: %s). Leave this window open; Ctrl+C stops it.\n", buildinfo.FullVersion(), o.Port, o.Paths.LogFile())

	if !o.NoBonjour {
		go advertise(ctx, o, name, identity, logger)
	}
	listeners.Run(ctx)
	logger.Log("stopped")
	return nil
}

// advertise waits for Tailscale to say this computer's MagicDNS name, then announces _greenfield._tcp on the local network. The
// record carries that name, because the daemon is not reachable on the LAN itself.
func advertise(ctx context.Context, o ServeOptions, name func() string, identity *tailnet.CLI, logger *logsvc.Logger) {
	var address string
	for address == "" {
		if me, _, ok := tailnet.ParseStatus(identity.StatusData()); ok {
			address = me.DNSName
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
	host, _ := os.Hostname()
	r := &mdns.Responder{Service: mdns.Service{Instance: name(), Type: mdns.DefaultType, Host: mdns.HostLabel(host), Port: o.Port,
		TXT: mdns.TXTRecords(name(), address, buildinfo.Version)}, Log: logger.Log}
	if err := r.Start(); err != nil {
		logger.Log("local-network discovery is off: " + logsvc.Redact(err.Error()))
		return
	}
	<-ctx.Done()
	r.Stop()
}

func fileSHA(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return "unknown"
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// dryRun types nothing: for trying the connection from the phone without a keyboard in the way.
type dryRun struct{}

func (dryRun) Insert(string, inserter.Method) (inserter.Outcome, error) {
	return inserter.Outcome{Method: inserter.Type, Delivery: inserter.Unconfirmed}, nil
}
