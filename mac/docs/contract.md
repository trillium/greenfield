# The daemon's side of the contract with the phone app

The phone's side (what it sends, how it reads answers) is `docs/mac-contract.md` at the repository root; this page
is the daemon's side. The same rule is in both. The version is the compatibility contract.

## Versions and the rule

Both programs carry a real `MAJOR.MINOR.PATCH` taken from the newest `vX.Y.Z` git tag of this repository
(`scripts/version.sh`, `docs/versioning.md`). Nothing types a version in by hand: `mac/scripts/stamp-version.sh` writes
`Sources/InserterCore/GeneratedVersion.swift` (gitignored) from the tags before every build, and `make install` and
`greenfield-inserter version` print the stamped version, commit and a hash of the binary.

**Rule.** While MAJOR is 0 the MINOR of the app and the MINOR of the daemon must match (patch is free). From 1.0.0 the
MAJOR must match (minor and patch are free). A wire change that breaks the other side bumps MINOR while MAJOR is 0 and
MAJOR from 1.0.0 on. Each side also declares the oldest peer it works with: the daemon's `min_client_version` is the
file `mac/min-client-version`; the app declares `GREENFIELD_MIN_PEER_VERSION`. A peer older than that is incompatible
even if the rule alone would accept it.

The 0.2 line is a breaking change from 0.1.x: authorization moved from a per-Mac key to tailnet identity, and `POST /text`
answers now carry `delivery` and can be 502.

## Fields

| Where | Field | Meaning |
|---|---|---|
| every request, header | `X-Greenfield-App: <semver>` | sent by the app; the daemon remembers the last 5 distinct versions with the time (`clients.json`) and checks the rule. A request without it (curl, the selftest) is let through |
| `GET /status` | `version` | the daemon's version (from the tag) |
| `GET /status` | `min_client_version` | the oldest app the daemon accepts |
| `GET /status` | `app_compatible` | `{ok, message, fix}`: the daemon's view of the newest app it has seen. `ok: true` with message `no app has connected yet` is a note, not a failure |
| `GET /status` | `clients` | `[{version, at}]`, newest first |
| `GET /status` | `build` | `{version, commit, binary_sha, started_at}` of the RUNNING process; `binary_sha` is the first 16 hex characters of the SHA-256 of its executable |
| `GET /status` | `auth`, `tailnet_user`, `key_configured`, `identity_ok` | authorization is by tailnet identity (`auth: "tailnet"`); a key is optional |
| `GET /status` | `can_insert`, `delivery_message`, `delivery_fix`, `delivery{ok,can_insert,state,message,text,fix,at,source}` | evidence that text really arrives |
| `POST /text` answer | `delivery` | `confirmed` (the focused field was read back and holds the text) or `unconfirmed` (a target that does not expose its text, or a key press) |
| any route | HTTP 426 | the app fails the rule or is older than `min_client_version`. Body: `{ok:false, error, message, version, min_client_version}` with `error` one of `app_too_old`, `app_too_new`, `app_version_unreadable` |

Other statuses of `POST /text`: 401 (a device of a different tailnet user, or a wrong key), 409 `secure_input`, 423
`screen_locked`, 502 `not_delivered`, 503 `accessibility_not_granted` or `identity_unavailable`.

## Logs (`GET /logs`)

`GET /logs?tail=N&since=30m&format=json|text` returns this Mac's daemon log, redacted, newest last: `{ok, name, version,
generated_at, tail, since_s, count, bytes, truncated, lines[]}`, or the bare lines with `format=text`. `tail` is 1 to 2000 (default
200), `since` up to 7 days, the answer at most 256 KiB (oldest lines dropped, `truncated: true`), at most 6 answered requests a
minute (429 with `Retry-After`). Same authorization as `/status`, except the optional key does not open it (403
`logs_need_same_user`), and no `X-Greenfield-App` gate (a Mac with a mismatched app still gives its logs). An unknown parameter is
400, a missing log file 404 `no_log`. `GET /status` reports `logs_available` and `logs{route,max_lines,max_bytes}`; `health` and
`doctor` show "Logs available" (a warning, never a failure). Additive: ships with 0.3 (MINOR bump, so app and daemon stay on one
line). The log holds ids, counts, lengths, timings, states and error text only (`docs/logs.md` at the repository root).

## Assist tools (`/assist/...`)

The window switcher and the trackpad for the phone's assist tools. The wire formats are the shared kit's (`KitAssist`, its
`docs/assist.md` and recorded fixtures); the daemon's rules, limits and security model are in `mac/docs/assist-pointer.md`. Additive: ships
with the 0.4 line (MINOR bump, so app and daemon stay on one line).

| Route | |
|---|---|
| `GET /assist/windows[?since=&epoch=]` | apps and windows (most recently used first), or `{format, unchanged, epoch, rev}` |
| `POST /assist/windows/focus` | `{format, action: app\|window\|previous, appId?, windowId?, rev}` answered `{format, result, reason?, rev, frontmost?}` |
| `POST /assist/pointer/session` | opens a pointer session: `{session, key, tag, udp{address,port}, idle_timeout_s, max_lifetime_s, capabilities}` |

Everything is **off by default** (`greenfield-inserter assist on`; the pointer has its own switch). Authorization is the tailnet identity as
for `POST /text`, but a caller that only holds the optional key is refused: 403 `assist_need_same_user`. Statuses: 200 for any answer
including `declined`, `notFound`, `denied`, `locked` (the body is the truth), 400 a body or query that breaks the contract, 404 `assist_off`
(off, or this daemon has no such tool: the phone hides it), 405, 409 `secure_input` (the list only), 413 a body over 1024 bytes, 423
`screen_locked` (the pointer handshake), 426 the version rule, 429 `rate_limited` / `too_many_sessions` (`Retry-After`), 503
`no_listener`.

`GET /status` adds `assist: {enabled, windows, pointer, capabilities}`: `enabled` is the master switch, `windows` and `pointer` say the
tool answers right now, `capabilities` is a list of names (`windowTitles`, ...). An older daemon has no `assist` field. Window titles,
application names and window ids are never logged; the log holds counts and results only.

## Finding computers (discovery)

A phone needs only one seed; it then lists every compatible Mac.

- `GET /peers` returns `{"ok": true, "peers": [{"name", "address", "version", "self"}]}`: this Mac and every other online macOS
  device of the SAME tailnet user whose daemon answers `GET /status` (`address` is the MagicDNS name, `name` the Mac's own name,
  `version` its daemon version). Only the Mac's own tailnet user (or this Mac) may ask: a device that got in with the optional
  key gets 403 `peers_need_same_user`. The answer is cached for 20 seconds. Fixture: `mac/Tests/Fixtures/peers-two-macs.json`.
- Bonjour: the daemon advertises `_greenfield._tcp` on the daemon's port with TXT records `name`, `address` (the tailnet name to
  connect to: the daemon itself listens only on the tailnet and loopback, so the LAN address Bonjour resolves is not usable),
  `version` and `path=/status`.
- `greenfield://add?name=<name>&address=<magicdns name>` adds one Mac with no typing. `greenfield-inserter link` prints it and a
  QR code (`--dark-terminal` inverts the code for a dark terminal; `--no-qr` omits it); `make install` shows it at the end.

## Verdict, per computer

- *compatible*: the rule holds and neither minimum is violated.
- *update the Mac daemon*: the daemon is older than the app's minimum or on an older line, or states no version.
- *update the app*: the app is older than `min_client_version`, or the daemon is on a newer line than the app.

The daemon's own `health` and `doctor` apply the same rule to the apps they have seen (`App compatible` line, a warning
if the newest app is outside the supported range) and between this Mac's `greenfield-inserter` and each remembered Mac
(`macs health`).

## Contract tests

Each side parses the other side's recorded samples.

- `mac/Tests/Fixtures/status-*.json` is what the daemon answers (HTTP status in `_http_status`). The real handler
  produces them; `ContractTests` fails if the handler's answer drifts from them. Re-record deliberately with
  `RECORD_FIXTURES=1 swift test --filter ContractTests/testRecordedStatusSamples`. The phone's tests parse every file
  and require a semver `version` and `min_client_version`.
- `App/Tests/Fixtures/request-*.json` is what the phone sends. `ContractTests.testTheDaemonAcceptsExactlyWhatThePhoneRecordsItSends`
  feeds each one to the handler and requires 200; it is skipped where those files are absent (set `APP_FIXTURES=<dir>` to
  point at them).
