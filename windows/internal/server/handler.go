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
	loggable    = func() map[string]bool {
		m := map[string]bool{"/health": true}
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
	if req.method == http.MethodPost && r.URL.Path == "/text" {
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
	if req.path == "/health" {
		return h.health(req)
	}
	wanted, ok := known[req.path]
	if !ok {
		wanted, ok = assistPaths[req.path]
	}
	if !ok {
		return errorResponse(404, "not_found", "unknown path")
	}
	// Authorize before revealing anything else, including whether the method is right.
	if denied := h.authorize(req); denied != nil {
		return *denied
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

// authorize: who may use the daemon is this computer itself, or any device of the same tailnet user as this computer's own node
// (asked of the local Tailscale). If Tailscale cannot say who is calling, the request is refused: it fails closed. There is no key
// and no password; a device of another user, a tagged device and a request carrying a key header are all refused.
func (h *Handler) authorize(req request) *response {
	if req.fromLoopback {
		return nil
	}
	var refusal response
	if req.peer != "" && h.c.Identity != nil {
		p := h.c.Identity.Identify(req.peer)
		switch p.Kind {
		case tailnet.SameUser:
			return nil
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
		r := errorResponse(401, "unauthorized", "this computer does not use keys; it takes text from devices of its own tailnet user only")
		return &r
	}
	return &refusal
}

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
