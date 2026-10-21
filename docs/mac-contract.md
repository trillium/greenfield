# Mac input agent: what the phone speaks

The phone sends text to a small agent on each Mac, `greenfield-inserter` (its own project; protocol and setup in its `mac/README.md`), which inserts the text at the cursor of the focused app. This page is the phone's side: which parts of that API the app uses and how it reads the answers. `tools/stub-receiver/receiver.py` speaks the same API without inserting anything, for tests.

## Versions and compatibility
The app and the agent are versioned with real semver, `MAJOR.MINOR.PATCH`, taken from the newest `vX.Y.Z` git tag of this repository by `scripts/version.sh` (see `docs/versioning.md`); nothing in either program types a version in by hand. The version is the compatibility contract.

**Rule.** While MAJOR is 0, the MINOR of the app and the MINOR of the agent must match (patch is free). From 1.0.0, the MAJOR must match (minor and patch are free). A wire change that breaks the other side bumps MINOR while MAJOR is 0, and MAJOR from 1.0.0 on.

**Each side also declares the oldest peer it works with**, `min_peer_version`. The agent reports it in `GET /status` as `min_client_version`; the app declares `GREENFIELD_MIN_PEER_VERSION` in `Config/Base.xcconfig` (the oldest agent). A peer older than that is incompatible even if the rule alone would accept it.

| Where | Field | Meaning |
|---|---|---|
| every request, header | `X-Greenfield-App: <semver>` | the app's own version; the agent remembers the last few clients (version and time) it has seen |
| `GET /status` | `version` | the agent's version |
| `GET /status` | `min_client_version` | the oldest app the agent accepts |
| `GET /status` | `app_compatible` (optional) | the Mac's own view of the clients it has seen: `{"ok": bool, "message": "...", "fix": "..."}` |
| any route | HTTP 426 | the app is older than `min_client_version` or fails the rule; the body says so in plain words |

**Verdict, per computer** (phone Health; the agent's `health` and `doctor` apply the same rule to the clients they have seen):
- *compatible*: the rule holds and neither minimum is violated.
- *update the Mac daemon*: the agent is older than the app's minimum, is on an older line than the app, or states no version at all (it predates this contract).
- *update the app*: the app is older than the agent's `min_client_version`, or the agent is on a newer line than the app.

A Mac that no app has connected to yet is a note, never a failure.

**Contract tests.** Each side parses the other side's recorded samples. The phone records what it sends in `App/Tests/Fixtures/request-*.json` (the phone's tests check the real client still produces exactly those fields); the Mac records what the daemon answers in `mac/Tests/Fixtures/status-*.json` (the phone's tests parse every file there and require a semver `version` and `min_client_version`).

## Transport and trust
- Port: `GREENFIELD_PORT` (the default is in `.env.example`; the phone offers the same default for a computer given without a port). Plain HTTP over the tailnet. The trust boundary is tailnet membership: the agent trusts callers by their tailnet identity, so the app needs no key and the preset computers work out of the box. The app can still send an optional key in the `X-Dictation-Key` header (Computers > Advanced; never in a URL, a log or the repository; kept in the iPhone Keychain, this device only). A 401 is shown as "this computer will not take text from this phone" only when the agent asks for one or refuses the saved one.
- iOS App Transport Security allows plain http to `*.ts.net` (subdomains included) and to local short names; there is no blanket exception. 100.x tailnet addresses are sent over a plain TCP transport (`HTTPTransport.swift`) because ATS cannot allow an address range. Before sending to a tailnet name or address the app checks that the phone is on the tailnet and says so if it is not.
- Audio is never sent to a Mac. Only text is. (Sounds recorded under Teach go to the user's own trainer instead, `docs/teach-protocol.md`.)

## `GET /status`
Used for the status line and dot beside each computer. The app reads `name`, `version`, `min_client_version`, `app_compatible`, `screen_locked`, `secure_input`, `accessibility` and `inserted_count`:

| Answer | Shown as |
|---|---|
| 200, everything fine | green: "Ready (agent <version>)" |
| 200, `accessibility` false | orange: needs Accessibility approval on that computer |
| 200, `screen_locked` | orange: ready, but its screen is locked |
| 200, `secure_input` | orange: ready, but a password field is focused |
| 401 | orange: the agent asks for a key (or refuses the saved one); update the agent on that Mac, or remove a saved key under Advanced |
| 503 `key_not_configured` | orange: an older agent that is not set up yet; update and restart it |
| no answer | red: the reason (not on the tailnet, unreachable, timed out) |

A computer with no key saved is checked like any other; a missing key is never reported as a problem.

## `GET /logs`
Not used by the phone's sending path; it is how a person (or `make logs`) asks a Mac for its own recent log when something is not working. Authorized like every other route (this Mac, or a device of its tailnet user; the optional key is *not* enough, 403 `logs_need_same_user`), with no `X-Greenfield-App` gate. Parameters: `tail` 1 to 2000 (default 200), `since` up to 7 days (`90s`, `30m`, `2h`, `1d`), `format` `json` (default) or `text`.

| Status / `error` | Meaning |
|---|---|
| 200 | `{ok, name, version, generated_at, tail, since_s, count, bytes, truncated, lines[]}`; at most 256 KiB, newest lines kept; every line redacted, never dictated text or a key |
| 400 `bad_request` | an unknown or out-of-range parameter |
| 401 / 503 `identity_unavailable` | refused / Tailscale could not say who is calling (fails closed) |
| 404 `no_log` | the daemon has no log file yet (an older daemon answers 404 `not_found`) |
| 429 `rate_limited` | more than 6 answered requests in a minute (`Retry-After`) |

`GET /status` adds `logs_available` (bool) and `logs` (`route`, `max_lines`, `max_bytes`). Contract version: this route is additive and ships with the 0.3 line (MINOR bump 0.2 to 0.3, so the app and every daemon move together; `docs/versioning.md`). More: `docs/logs.md`.

## Assist tools (`/assist/...`)
The window switcher and the trackpad. Not used by the sending path. The wire formats are the shared kit's (`KitAssist`, `docs/assist.md` there); the daemon's side, limits and security model are in `mac/docs/contract.md` and `mac/docs/assist-pointer.md`. `GET /status` adds `assist: {enabled, windows, pointer, capabilities}` (absent on an older daemon: no assist tools). All three routes are off by default on the Mac (404 `assist_off`: hide the tool), refuse a caller that only holds the optional key (403 `assist_need_same_user`), and ship with the 0.4 line (additive, MINOR bump).

## `POST /text`
```json
{ "id": "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E", "text": "Hello, world.", "source": "greenfield" }
```
`id` is generated once per submitted text and reused on every resend; the agent answers a repeat with `200` and `"duplicate": true` and types nothing. The phone sends one line per submit, up to 256 KiB.

| Status / `error` | Meaning in the app |
|---|---|
| 200 | sent (a duplicate counts as sent) |
| 401 `unauthorized` | the computer will not take text from this phone (the agent asks for a key, or refuses the saved one) |
| 503 `key_not_configured` | an older agent that is not set up yet |
| 503 `accessibility_not_granted` | the agent needs Accessibility approval |
| 409 `secure_input` | a password field is focused; nothing typed |
| 423 `screen_locked` | the screen is locked; nothing typed |
| 400 `bad_request`, 413 `too_large`, 500 `insert_failed` | refused, with a message |
| no answer or a timeout | unreachable; the text may or may not have arrived, and the id makes a resend safe |

Only a 200 counts as delivered. Everything else keeps the text in the outbox, where it can be sent again with the same `id`.

## Which computer
Exactly one computer per submit: the active one, chosen in the Computers tab. The phone never broadcasts and never falls back to another computer when the active one fails.
