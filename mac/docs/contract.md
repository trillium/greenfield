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

0.2.0 is a breaking change from 0.1.x: authorization moved from a per-Mac key to tailnet identity, and `POST /text`
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
