// Package server is the daemon's whole HTTP surface: the same routes, JSON shapes, status codes and error codes the Mac daemon
// speaks, so the phone needs no change to talk to a Windows computer. It is free of Win32 calls: the system, the inserter, the
// Tailscale identity and the stores are interfaces, so every route is tested on any machine.
package server

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"greenfield-inserter/internal/compat"
	"greenfield-inserter/internal/inserter"
	"greenfield-inserter/internal/logsvc"
	"greenfield-inserter/internal/pairing"
	"greenfield-inserter/internal/state"
	"greenfield-inserter/internal/tailnet"
)

// ServiceName is `service` in GET /status.
const ServiceName = "greenfield-inserter"

// Limits.
const (
	MaxTextBytes = 256 * 1024
	maxBodyBytes = 1024 * 1024
)

// SystemProbe is what the daemon needs to know about the computer right now.
type SystemProbe interface {
	// SecureInput: a password field has the keyboard (best effort; the same role as the Mac's secure input).
	SecureInput() bool
	// ScreenLocked: the lock screen, a secure desktop or a disconnected session is in front.
	ScreenLocked() bool
	// InputAllowed: can this program type into the app in front? When not, why (an app running as administrator has the focus).
	InputAllowed() (ok bool, why string)
}

// DeliveryRecord is the evidence that text really arrives.
type DeliveryRecord interface {
	RecordSuccess(source string)
	RecordFailure(source, detail string)
	CanInsert() state.CanInsert
}

// ClientRecord remembers the app versions seen.
type ClientRecord interface {
	Saw(version string)
	Recent() []compat.Sighting
}

// Logger receives metadata only; never inserted text.
type Logger interface{ Log(message string) }

// Build is what the running process is.
type Build struct {
	Version   string
	Commit    string
	BinarySHA string
	StartedAt string
}

// Config wires a Handler.
type Config struct {
	Probe     SystemProbe
	Inserter  inserter.Inserter
	Identity  tailnet.Identity
	Record    DeliveryRecord
	Clients   ClientRecord
	Discovery tailnet.Discovery
	Logger    Logger
	LogSource logsvc.Source
	Limiter   *logsvc.RateLimiter
	Dedupe    *state.Dedupe
	// Pairing is the one-time pairing of a browser outside the tailnet (the PWA); nil gets a fresh in-memory book.
	Pairing pairing.Book

	Name      func() string
	Listening func() []string
	Version   string
	MinClient string
	Build     Build
	// Executable is the path of the running program, reported by the loopback-only /health.
	Executable string
	Now        func() time.Time
}

// Handler is the daemon's HTTP surface.
type Handler struct {
	c       Config
	started time.Time

	mu       sync.Mutex   // one text at a time: a concurrent retry of the same id waits and then finds the first answer cached
	inserted atomic.Int64 // read by /status without waiting for a text that is being typed
}

// New makes a Handler. Missing optional parts get harmless defaults.
func New(c Config) *Handler {
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Limiter == nil {
		c.Limiter = logsvc.NewRateLimiter()
	}
	if c.Dedupe == nil {
		c.Dedupe = state.NewDedupe()
	}
	if c.Pairing == nil {
		c.Pairing = pairing.New()
	}
	if c.Name == nil {
		c.Name = func() string { return "Windows computer" }
	}
	if c.Listening == nil {
		c.Listening = func() []string { return []string{} }
	}
	return &Handler{c: c, started: c.Now()}
}

type request struct {
	method, path, query string
	headers             map[string]string // lowercased names
	body                []byte
	bodyErr             *response
	fromLoopback        bool
	peer                string
}

type response struct {
	status  int
	headers map[string]string
	body    []byte
}

func jsonResponse(status int, v map[string]any) response {
	data, err := json.Marshal(v) // map keys are sorted, like the Mac daemon's answers
	if err != nil {
		data = []byte("{}")
	}
	return response{status: status, headers: map[string]string{"Content-Type": "application/json"}, body: data}
}

func errorResponse(status int, code, message string) response {
	return jsonResponse(status, map[string]any{"ok": false, "error": code, "message": message})
}

func (r response) with(k, v string) response {
	h := map[string]string{}
	for a, b := range r.headers {
		h[a] = b
	}
	h[k] = v
	r.headers = h
	return r
}

// The paths this daemon answers; anything else is logged as "(unknown)".
var (
	assistPaths = map[string]string{"/assist/windows": "GET", "/assist/windows/focus": "POST", "/assist/pointer/session": "POST"}
	known       = map[string]string{"/status": "GET", "/text": "POST", "/peers": "GET", "/logs": "GET"}
	// pairPaths: one-time pairing of a browser outside the tailnet (the PWA), see internal/pairing.
	pairPaths = map[string]string{"/pair": "POST", "/pair/code": "POST", "/pair/devices": "GET", "/pair/revoke": "POST"}
	loggable  = func() map[string]bool {
		m := map[string]bool{"/health": true}
		for p := range pairPaths {
			m[p] = true
		}
		for p := range known {
			m[p] = true
		}
		for p := range assistPaths {
			m[p] = true
		}
		return m
	}()
)

// ServeHTTP implements http.Handler.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	req := h.read(r)
	resp := h.Handle(req)
	for k, v := range resp.headers {
		w.Header().Set(k, v)
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "close")
	w.WriteHeader(resp.status)
	_, _ = w.Write(resp.body)
}

func (h *Handler) read(r *http.Request) request {
	req := request{method: strings.ToUpper(r.Method), path: r.URL.Path, query: r.URL.RawQuery, headers: map[string]string{}}
	for k := range r.Header {
		req.headers[strings.ToLower(k)] = r.Header.Get(k)
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		if ip := net.ParseIP(host); ip != nil {
			req.fromLoopback = ip.IsLoopback()
			if v4 := ip.To4(); v4 != nil {
				req.peer = v4.String()
			}
		}
	}
	_, isPair := pairPaths[r.URL.Path]
	if req.method == http.MethodPost && (r.URL.Path == "/text" || isPair) {
		if len(r.TransferEncoding) > 0 {
			e := errorResponse(501, "not_implemented", "chunked bodies are not supported")
			req.bodyErr = &e
		} else if r.ContentLength < 0 {
			e := errorResponse(411, "length_required", "Content-Length is required")
			req.bodyErr = &e
		} else if r.ContentLength > maxBodyBytes {
			e := errorResponse(413, "too_large", "body too large")
			req.bodyErr = &e
		} else if body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1)); err != nil {
			e := errorResponse(400, "bad_request", "could not read the body")
			req.bodyErr = &e
		} else {
			req.body = body
		}
	}
	return req
}

// Handle answers one request. It never reveals anything before authorizing, except that /health is for this computer only.
func (h *Handler) Handle(req request) response {
	resp := h.route(req)
	// The path is logged only when it is one of ours: an unknown path is caller-controlled text.
	if h.c.Logger != nil {
		h.c.Logger.Log(logsvc.Token(req.method) + " " + logsvc.Path(req.path, loggable) + " -> " + strconv.Itoa(resp.status))
	}
	return resp
}

func (h *Handler) route(req request) response {
	// A request that went through a reverse proxy (`tailscale serve`, the PWA's server) reaches us from loopback, but it is not the
	// person at this computer and its TCP peer says nothing about who is calling: it is neither local nor identifiable. Only a paired
	// device's token lets it in. The tailnet-identity path below is untouched for every request that carries no proxy header.
	if pairing.Proxied(req.headers) {
		req.fromLoopback, req.peer = false, ""
	}
	if req.path == "/health" {
		return h.health(req)
	}
	if _, ok := pairPaths[req.path]; ok {
		return h.pair(req)
	}
	wanted, ok := known[req.path]
	if !ok {
		wanted, ok = assistPaths[req.path]
	}
	if !ok {
		return errorResponse(404, "not_found", "unknown path")
	}
	// Authorize before revealing anything else, including whether the method is right.
	denied, via := h.authorize(req)
	if denied != nil {
		return *denied
	}
	// A paired browser may send text and read the status, like a caller with the optional key on the Mac: not the computer list, the
	// logs or the assist tools.
	if via == viaToken {
		switch req.path {
		case "/logs":
			return errorResponse(403, "logs_need_same_user", "logs are only shown to this computer and to devices of its tailnet user")
		case "/peers":
			return errorResponse(403, "peers_need_same_user", "the computer list is only shown to devices of this computer's tailnet user")
		}
		if _, isAssist := assistPaths[req.path]; isAssist {
			return errorResponse(403, "assist_need_same_user", "the assist tools are only for this computer and devices of its tailnet user")
		}
	}
	// Logs are for a person debugging, so a computer with a wrong or old app still answers them: no app-version gate here.
	if req.path == "/logs" {
		return h.logs(req)
	}
	if refused := h.checkAppVersion(req); refused != nil {
		return *refused
	}
	if _, isAssist := assistPaths[req.path]; isAssist {
		return errorResponse(404, "assist_off", "the assist tools (window switcher and trackpad) are not supported on this computer")
	}
	if req.method != wanted {
		return errorResponse(405, "method_not_allowed", "use "+wanted).with("Allow", wanted)
	}
	switch req.path {
	case "/status":
		return jsonResponse(200, h.statusFields())
	case "/peers":
		return h.peers()
	default:
		return h.postText(req)
	}
}

// authorize: who may use the daemon is this computer itself, any device of the same tailnet user as this computer's own node
// (asked of the local Tailscale), or a browser paired at this computer, which presents its token. If Tailscale cannot say who is
// calling and there is no valid token, the request is refused: it fails closed. There is no key and no password; a device of another
// user, a tagged device and a request carrying a key header are all refused.
func (h *Handler) authorize(req request) (*response, via) {
	if req.fromLoopback {
		return nil, viaLocal
	}
	// A paired device (the PWA) presents its token; a wrong, expired or revoked one is refused, never retried as something else.
	if presented := req.headers["x-greenfield-token"]; presented != "" {
		if _, ok := h.c.Pairing.Verify(presented); ok {
			return nil, viaToken
		}
		r := errorResponse(401, "invalid_token", "this device is not paired (the token is wrong, expired or revoked); pair it again with a new code from this computer")
		return &r, viaToken
	}
	var refusal response
	if req.peer != "" && h.c.Identity != nil {
		p := h.c.Identity.Identify(req.peer)
		switch p.Kind {
		case tailnet.SameUser:
			return nil, viaIdentity
		case tailnet.OtherUser:
			refusal = errorResponse(401, "unauthorized", "this device belongs to a different tailnet user ("+p.Login+") than this computer")
		default:
			refusal = errorResponse(503, "identity_unavailable", "could not verify who is calling ("+p.Why+"); refusing the request")
		}
	} else {
		refusal = errorResponse(503, "identity_unavailable", "could not verify who is calling; refusing the request")
	}
	// The Mac daemon has an optional key for devices of other users. This one has none, by design: trust is the tailnet identity. A
	// request that offers a key anyway is refused as the Mac refuses a wrong one.
	if req.headers["x-dictation-key"] != "" {
		r := errorResponse(401, "unauthorized", "this computer does not use keys; it takes text from devices of its own tailnet user, or a browser paired at this computer")
		return &r, viaIdentity
	}
	return &refusal, viaIdentity
}

// via is how a caller got in.
type via int

const (
	viaLocal via = iota
	viaIdentity
	viaToken
)

// checkAppVersion: the app sends its own version in X-Greenfield-App. It is remembered (so health can report on the apps seen) and
// checked against the compatibility rule; a request without the header (curl, the selftest) is let through.
func (h *Handler) checkAppVersion(req request) *response {
	v := req.headers["x-greenfield-app"]
	if v == "" {
		return nil
	}
	if h.c.Clients != nil {
		h.c.Clients.Saw(v)
	}
	var code, message string
	switch compat.Judge(v, h.c.Version, h.c.MinClient) {
	case compat.Compatible:
		return nil
	case compat.PeerTooOld:
		code = "app_too_old"
		message = "this app (" + v + ") is too old for this computer's daemon (" + h.c.Version + "; oldest app it works with: " + h.c.MinClient + "). Update the app."
	case compat.PeerTooNew:
		code = "app_too_new"
		message = "this app (" + v + ") is newer than this computer's daemon (" + h.c.Version + ") supports. Update the daemon on this computer."
	default:
		code = "app_version_unreadable"
		shown := v
		if len(shown) > 40 {
			shown = shown[:40]
		}
		message = "X-Greenfield-App must be a version like 1.2.3, not \"" + shown + "\"."
	}
	r := jsonResponse(426, map[string]any{"ok": false, "error": code, "message": message, "version": h.c.Version, "min_client_version": h.c.MinClient}).with("Upgrade", "greenfield")
	return &r
}

// health is the same facts as /status plus what only the daemon itself can know, for `health` and `doctor` run on this computer.
// No credential is needed because it answers loopback peers only and holds nothing secret.
func (h *Handler) health(req request) response {
	if !req.fromLoopback {
		return errorResponse(403, "local_only", "/health is only for requests from this computer")
	}
	if req.method != "GET" {
		return errorResponse(405, "method_not_allowed", "use GET")
	}
	body := h.statusFields()
	body["pid"] = os.Getpid()
	body["executable"] = h.c.Executable
	return jsonResponse(200, body)
}

// pair is the one-time pairing (internal/pairing). Asking for a code, listing and revoking are for the person at this computer
// (loopback, no proxy header): the `greenfield-inserter pair` command. Exchanging a code is open to whoever can reach the port,
// because the code is the credential: short-lived, single use, burned by wrong guesses, rate limited. Nothing here logs a code or
// a token.
func (h *Handler) pair(req request) response {
	wrong := func(wanted string) response {
		return errorResponse(405, "method_not_allowed", "use "+wanted).with("Allow", wanted)
	}
	localOnly := errorResponse(403, "local_only", "this is only for the person at this computer: run `greenfield-inserter pair`")
	if want := pairPaths[req.path]; req.method != want {
		if (req.path == "/pair/code" || req.path == "/pair/devices") && !req.fromLoopback {
			return localOnly
		}
		return wrong(want)
	}
	switch req.path {
	case "/pair":
		if req.bodyErr != nil {
			return *req.bodyErr
		}
		var object map[string]any
		code, isString := "", false
		if json.Unmarshal(req.body, &object) == nil && object != nil {
			code, isString = object["code"].(string)
		}
		if !isString || len(code) > 32 {
			return errorResponse(400, "bad_request", `body must be {"code": "ABCD-EFGH", "device": "name"}`)
		}
		deviceName, _ := object["device"].(string)
		res := h.c.Pairing.Redeem(code, deviceName)
		switch res.Outcome {
		case pairing.SlowDown:
			return errorResponse(429, "rate_limited", "too many attempts; try again in "+strconv.Itoa(res.Wait)+" seconds").with("Retry-After", strconv.Itoa(res.Wait))
		case pairing.Refused:
			h.log("pair refused")
			return errorResponse(401, "pair_refused", "that code is wrong, already used or expired; ask for a new one at this computer with `greenfield-inserter pair`")
		}
		h.log("paired device id=" + res.Device.ID)
		return jsonResponse(200, map[string]any{"ok": true, "token": res.Token, "device": deviceJSON(res.Device),
			"expires_in_s": int(res.Device.ExpiresAt.Sub(h.c.Now()).Seconds()), "name": h.c.Name(), "version": h.c.Version})
	case "/pair/code":
		if !req.fromLoopback {
			return localOnly
		}
		c := h.c.Pairing.IssueCode()
		h.log("pair code issued")
		return jsonResponse(200, map[string]any{"ok": true, "code": c.Text, "expires_in_s": int(c.ExpiresIn.Seconds()), "name": h.c.Name()})
	case "/pair/devices":
		if !req.fromLoopback {
			return localOnly
		}
		list := h.c.Pairing.Devices()
		out := make([]map[string]any, 0, len(list))
		for _, d := range list {
			out = append(out, deviceJSON(d))
		}
		return jsonResponse(200, map[string]any{"ok": true, "devices": out})
	default: // /pair/revoke
		if req.fromLoopback {
			var object map[string]any
			if req.bodyErr != nil {
				return *req.bodyErr
			}
			if json.Unmarshal(req.body, &object) != nil || object == nil {
				return errorResponse(400, "bad_request", `body must be {"id": "..."} or {"all": true}`)
			}
			if all, _ := object["all"].(bool); all {
				n := h.c.Pairing.RevokeAll()
				h.log("pair revoked all devices=" + strconv.Itoa(n))
				return jsonResponse(200, map[string]any{"ok": true, "revoked": n})
			}
			id, _ := object["id"].(string)
			if id == "" {
				return errorResponse(400, "bad_request", `body must be {"id": "..."} or {"all": true}`)
			}
			if !h.c.Pairing.Revoke(id) {
				return errorResponse(404, "no_such_device", "no paired device has that id")
			}
			h.log("pair revoked id=" + logsvc.ID(id))
			return jsonResponse(200, map[string]any{"ok": true, "revoked": 1})
		}
		// A paired device may forget itself: its own token, nothing else.
		dev, ok := h.c.Pairing.Verify(req.headers["x-greenfield-token"])
		if !ok {
			return errorResponse(401, "unauthorized", "present this device's token, or run `greenfield-inserter pair --revoke` at this computer")
		}
		h.c.Pairing.Revoke(dev.ID)
		h.log("pair device left id=" + dev.ID)
		return jsonResponse(200, map[string]any{"ok": true, "revoked": 1})
	}
}

func deviceJSON(d pairing.Device) map[string]any {
	var seen any
	if !d.LastSeen.IsZero() {
		seen = d.LastSeen.UTC().Format(time.RFC3339)
	}
	return map[string]any{"id": d.ID, "name": d.Name, "created_at": d.CreatedAt.UTC().Format(time.RFC3339),
		"expires_at": d.ExpiresAt.UTC().Format(time.RFC3339), "last_seen": seen}
}

func (h *Handler) peers() response {
	var list []tailnet.Computer
	if h.c.Discovery != nil {
		list = h.c.Discovery.Computers()
	}
	out := make([]map[string]any, 0, len(list))
	for _, c := range list {
		out = append(out, map[string]any{"name": c.Name, "address": c.Address, "version": c.Version, "self": c.Self})
	}
	return jsonResponse(200, map[string]any{"ok": true, "peers": out})
}
