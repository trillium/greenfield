package server

import (
	"encoding/json"
	"errors"
	"strconv"
	"unicode/utf8"

	"greenfield-inserter/internal/inserter"
	"greenfield-inserter/internal/logsvc"
	"greenfield-inserter/internal/state"
)

func (h *Handler) postText(req request) response {
	if req.bodyErr != nil {
		return *req.bodyErr
	}
	var object map[string]any
	if err := json.Unmarshal(req.body, &object); err != nil || object == nil {
		return errorResponse(400, "bad_request", "body must be a JSON object")
	}
	id, _ := object["id"].(string)
	if _, has := object["id"].(string); !has {
		id = req.headers["x-request-id"]
	}
	if id == "" || utf8.RuneCountInString(id) > 128 {
		return errorResponse(400, "bad_request", "id is required (string, up to 128 characters)")
	}
	sent, _ := object["text"].(string)
	if sent == "" {
		return errorResponse(400, "bad_request", "text is required and must not be empty")
	}
	if len(sent) > MaxTextBytes {
		return errorResponse(413, "too_large", "text too large")
	}
	// One line ending for everything downstream: a Return key press when typed.
	text := inserter.NormalizeNewlines(sent)
	var method inserter.Method
	if raw, has := object["method"]; has {
		s, isString := raw.(string)
		if !isString || (s != "paste" && s != "type") {
			return errorResponse(400, "bad_request", "method must be \"paste\" or \"type\"")
		}
		method = inserter.Method(s)
	}
	source := "unknown"
	if s, ok := object["source"].(string); ok {
		source = logsvc.SourceLabel(s)
	}
	logID := logsvc.ID(id)

	h.mu.Lock()
	defer h.mu.Unlock()

	if previous, ok := h.c.Dedupe.Lookup(id); ok {
		body := map[string]any{"ok": true}
		_ = json.Unmarshal(previous.Body, &body)
		body["duplicate"] = true
		h.log("text id=" + logID + " source=" + source + " duplicate")
		return jsonResponse(200, body)
	}
	if h.c.Probe != nil {
		if h.c.Probe.ScreenLocked() {
			h.log("text id=" + logID + " source=" + source + " refused: screen locked")
			return errorResponse(423, "screen_locked", "the screen is locked")
		}
		if h.c.Probe.SecureInput() {
			h.log("text id=" + logID + " source=" + source + " refused: secure input")
			return errorResponse(409, "secure_input", "secure input is on (a password field is focused)")
		}
		if ok, why := h.c.Probe.InputAllowed(); !ok {
			h.log("text id=" + logID + " source=" + source + " refused: input not allowed")
			return errorResponse(503, "accessibility_not_granted", notAllowed(why))
		}
	}
	used, err := h.c.Inserter.Insert(text, method)
	switch {
	case err == nil:
		h.inserted.Add(1)
		if used.Delivery == inserter.Confirmed && h.c.Record != nil {
			h.c.Record.RecordSuccess("delivery")
		}
		h.log("text id=" + logID + " source=" + source + " sent chars=" + strconv.Itoa(utf8.RuneCountInString(text)) + " method=" + string(used.Method) + " delivery=" + string(used.Delivery))
		resp := jsonResponse(200, map[string]any{"ok": true, "id": id, "chars": utf8.RuneCountInString(text), "method": string(used.Method), "delivery": string(used.Delivery)})
		h.c.Dedupe.Remember(id, state.Response{Status: resp.status, Body: resp.body})
		return resp
	case errors.Is(err, inserter.ErrBlocked):
		h.log("text id=" + logID + " source=" + source + " refused: input blocked by Windows")
		return errorResponse(503, "accessibility_not_granted", notAllowed("Windows blocked the input"))
	case errors.Is(err, inserter.ErrNotDelivered):
		if h.c.Record != nil {
			h.c.Record.RecordFailure("delivery", "the focused field did not change after the keys were sent")
		}
		h.log("text id=" + logID + " source=" + source + " not delivered: the focused field did not change")
		return errorResponse(502, "not_delivered", "the keys were sent but the focused field did not change; nothing was inserted")
	default:
		h.log("text id=" + logID + " source=" + source + " failed: " + logsvc.Redact(err.Error()))
		return errorResponse(500, "insert_failed", "could not insert the text")
	}
}

func notAllowed(why string) string {
	if why == "" {
		why = "Windows will not let greenfield-inserter type into the app in front"
	}
	return why + ". Usually that app runs as administrator: close it, or start greenfield-inserter as administrator too."
}
