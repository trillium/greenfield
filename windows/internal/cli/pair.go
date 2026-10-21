package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"
)

// localCall is a request to this computer's own daemon on loopback.
func localCall(port int, method, path string, body map[string]any) (int, map[string]any, error) {
	var payload io.Reader
	if method == "POST" {
		raw, _ := json.Marshal(body)
		if body == nil {
			raw = []byte("{}")
		}
		payload = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, "http://"+net.JoinHostPort("127.0.0.1", strconv.Itoa(port))+path, payload)
	if err != nil {
		return 0, nil, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var answer map[string]any
	_ = json.Unmarshal(raw, &answer)
	return resp.StatusCode, answer, nil
}

// pair: a one-time code for a browser outside the tailnet, or the list of paired devices, or a revoke. All of it is the running
// daemon's; this command only asks it on loopback.
func (d *Deps) pair(args []string) int {
	port, code := d.port(args)
	if code != 0 {
		return code
	}
	ask := func(method, path string, body map[string]any) (map[string]any, bool) {
		status, answer, err := d.Local(port, method, path, body)
		switch {
		case err != nil:
			fmt.Fprintf(d.Err, "the daemon is not answering on 127.0.0.1:%d; start it (`greenfield-inserter serve`) or check `greenfield-inserter health`\n", port)
		case status == 404 && answer["error"] == "not_found":
			fmt.Fprintln(d.Err, "this daemon predates browser pairing; update it")
		case status != 200:
			msg, _ := answer["message"].(string)
			if msg == "" {
				msg = "HTTP " + strconv.Itoa(status)
			}
			fmt.Fprintln(d.Err, msg)
		default:
			return answer, true
		}
		return nil, false
	}
	revoke, hasRevoke, err := option("--revoke", args)
	if err != nil {
		fmt.Fprintln(d.Err, err)
		return 2
	}
	switch {
	case has("--list", args):
		answer, ok := ask("GET", "/pair/devices", nil)
		if !ok {
			return 1
		}
		list, _ := answer["devices"].([]any)
		if len(list) == 0 {
			fmt.Fprintln(d.Out, "no paired devices")
		}
		for _, item := range list {
			dev, _ := item.(map[string]any)
			seen := "never"
			if s, ok := dev["last_seen"].(string); ok {
				seen = s
			}
			fmt.Fprintf(d.Out, "%v  %v  expires %v  last seen %s\n", dev["id"], dev["name"], dev["expires_at"], seen)
		}
	case has("--revoke-all", args):
		answer, ok := ask("POST", "/pair/revoke", map[string]any{"all": true})
		if !ok {
			return 1
		}
		n, _ := answer["revoked"].(float64)
		fmt.Fprintf(d.Out, "revoked %d device(s); any open code is gone too\n", int(n))
	case hasRevoke:
		if _, ok := ask("POST", "/pair/revoke", map[string]any{"id": revoke}); !ok {
			return 1
		}
		fmt.Fprintln(d.Out, "revoked", revoke)
	default:
		answer, ok := ask("POST", "/pair/code", nil)
		if !ok {
			return 1
		}
		minutes, _ := answer["expires_in_s"].(float64)
		fmt.Fprintf(d.Out, "Pairing code for %v:\n\n    %v\n\n", answer["name"], answer["code"])
		fmt.Fprintf(d.Out, "Type it into the Greenfield web app (Computers > Pair) within %d minutes. It works once.\n", int(minutes)/60)
		fmt.Fprintln(d.Out, "The browser gets a token for 24 hours that only sends text; `greenfield-inserter pair --list` shows it, `--revoke ID` ends it.")
	}
	return 0
}
