package server

import (
	"strconv"
	"strings"
	"time"

	"greenfield-inserter/internal/logsvc"
)

// logs serves the daemon's own recent log lines, redacted, newest last: same authorization as everything else, a limit on the
// number of requests and on the size of the answer. Unknown parameters, a missing log or a refused identity never fall back to
// "show it".
func (h *Handler) logs(req request) response {
	if req.method != "GET" {
		return errorResponse(405, "method_not_allowed", "use GET").with("Allow", "GET")
	}
	if h.c.LogSource == nil || !h.c.LogSource.Available() {
		return errorResponse(404, "no_log", "this daemon has no log file to show")
	}
	q, err := logsvc.ParseQuery(req.query)
	if err != nil {
		return errorResponse(400, "bad_request", err.Error())
	}
	now := h.c.Now()
	if wait := h.c.Limiter.Admit(now); wait > 0 {
		return errorResponse(429, "rate_limited", "too many log requests; try again in "+strconv.Itoa(wait)+" seconds").with("Retry-After", strconv.Itoa(wait))
	}
	page := logsvc.BuildPage(h.c.LogSource.Read(q, now), q)
	h.log("logs served lines=" + strconv.Itoa(len(page.Lines)) + " bytes=" + strconv.Itoa(page.Bytes) + " truncated=" + boolWord(page.Truncated))
	if q.PlainText {
		var b strings.Builder
		for _, l := range page.Lines {
			b.WriteString(l + "\n")
		}
		return response{status: 200, headers: map[string]string{
			"Content-Type": "text/plain; charset=utf-8", "X-Logs-Truncated": boolWord(page.Truncated), "X-Logs-Count": strconv.Itoa(len(page.Lines)),
		}, body: []byte(b.String())}
	}
	var since any
	if q.Since > 0 {
		since = int(q.Since.Seconds())
	}
	return jsonResponse(200, map[string]any{
		"ok": true, "service": ServiceName, "version": h.c.Version, "name": h.c.Name(),
		"generated_at": now.UTC().Format(time.RFC3339),
		"tail":         q.Tail, "since_s": since,
		"count": len(page.Lines), "bytes": page.Bytes, "truncated": page.Truncated, "lines": page.Lines,
	})
}

func boolWord(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func (h *Handler) log(m string) {
	if h.c.Logger != nil {
		h.c.Logger.Log(m)
	}
}
