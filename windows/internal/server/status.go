package server

import (
	"time"

	"greenfield-inserter/internal/compat"
	"greenfield-inserter/internal/logsvc"
	"greenfield-inserter/internal/state"
)

// statusFields is GET /status. Everything the Mac daemon reports is here with the same names and types; `platform` is the one
// addition. `accessibility` is whether Windows lets this program type into the app in front (there is no permission to grant);
// `secure_input` is a password field with the keyboard, detected for standard password boxes only.
func (h *Handler) statusFields() map[string]any {
	count := h.inserted.Load()
	now := h.c.Now()
	var seen []compat.Sighting
	if h.c.Clients != nil {
		seen = h.c.Clients.Recent()
	}
	clients := make([]map[string]any, 0, len(seen))
	for _, s := range seen {
		clients = append(clients, map[string]any{"version": s.Version, "at": s.At.UTC().Format(time.RFC3339)})
	}
	allowed, locked, secure := true, false, false
	if h.c.Probe != nil {
		allowed, _ = h.c.Probe.InputAllowed()
		locked, secure = h.c.Probe.ScreenLocked(), h.c.Probe.SecureInput()
	}
	var tailnetUser any
	identityOK := false
	if h.c.Identity != nil {
		if u := h.c.Identity.SelfLogin(); u != "" {
			tailnetUser, identityOK = u, true
		}
	}
	appCompat := compat.Evaluate(seen, h.c.Version, h.c.MinClient, now)
	fields := map[string]any{
		"ok": true, "service": ServiceName, "platform": "windows",
		"version": h.c.Version, "min_client_version": h.c.MinClient,
		"build":          map[string]any{"version": h.c.Build.Version, "commit": h.c.Build.Commit, "binary_sha": h.c.Build.BinarySHA, "started_at": h.c.Build.StartedAt},
		"app_compatible": map[string]any{"ok": appCompat.OK, "message": appCompat.Message, "fix": appCompat.Fix},
		"clients":        clients,
		"name":           h.c.Name(),
		"uptime_s":       int(now.Sub(h.started).Seconds()),
		"secure_input":   secure, "screen_locked": locked,
		"accessibility": allowed, "accessibility_at_start": true,
		"inserted_count": int(count),
		"listen":         h.c.Listening(),
		"auth":           "tailnet", "key_configured": false,
		"tailnet_user": tailnetUser, "identity_ok": identityOK,
		"assist":         map[string]any{"enabled": false, "windows": false, "pointer": false, "capabilities": []string{}},
		"logs_available": h.c.LogSource != nil && h.c.LogSource.Available(),
		"logs":           map[string]any{"route": "/logs", "max_lines": logsvc.MaxTail, "max_bytes": logsvc.MaxBytes},
	}
	for k, v := range h.deliveryFields() {
		fields[k] = v
	}
	return fields
}

// deliveryFields are the delivery line for GET /status, in the shapes the phone reads: flat `can_insert` (bool), `delivery_message`,
// `delivery_fix`, and the same inside a `delivery` object. `evidence` is the raw record.
func (h *Handler) deliveryFields() map[string]any {
	evidence := state.CanInsert{State: state.StateUnknown, Detail: "delivery is not tracked"}
	if h.c.Record != nil {
		evidence = h.c.Record.CanInsert()
	}
	message, fix := CanInsertLine(evidence, h.c.Now())
	ok := evidence.State == state.StateOK
	delivery := map[string]any{"ok": ok, "can_insert": ok, "state": string(evidence.State), "message": message, "text": message, "fix": fix}
	if evidence.At != nil {
		delivery["at"] = evidence.At.UTC().Format(time.RFC3339)
	}
	if evidence.Source != "" {
		delivery["source"] = evidence.Source
	}
	return map[string]any{"can_insert": ok, "delivery_message": message, "delivery_fix": fix, "delivery": delivery, "evidence": evidence.JSON()}
}

// CanInsertLine words the evidence: what is known, and what to do about it.
func CanInsertLine(c state.CanInsert, now time.Time) (message, fix string) {
	const onThisComputer = "On this computer"
	switch c.State {
	case state.StateOK:
		how := "by a real delivery"
		if c.Source == "selftest" {
			how = "by the selftest"
		}
		at := "at an unknown time"
		if c.At != nil {
			at = compat.AgeText(*c.At, now)
		}
		return "text was read back from a field " + at + " " + how, ""
	case state.StateFailed:
		at := "earlier"
		if c.At != nil {
			at = compat.AgeText(*c.At, now)
		}
		return "the last attempt " + at + " did not arrive: " + c.Detail,
			onThisComputer + ": run `greenfield-inserter doctor` (it re-runs the live test). Usual cause: the app in front runs as administrator, and Windows lets a normal program type only into normal apps; close it or start greenfield-inserter as administrator too."
	default:
		return c.Detail,
			onThisComputer + ": run `greenfield-inserter selftest` (opens a small window for a few seconds), or send one real text and `health` will pick up the confirmed delivery."
	}
}
