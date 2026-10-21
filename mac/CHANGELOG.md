# Changelog (greenfield-inserter, the Mac daemon)

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: `docs/versioning.md`. The repository has one
version line; entries here are the daemon's part of each release.

## [0.4.0] - 2026-10-21

### Added
- The assist tools for the phone's window switcher and trackpad, built on the shared kit's `KitAssist` types and tested against its recorded fixtures. **Off until `greenfield-inserter assist on`**; `assist off` is the kill switch and takes effect at once. The kit is a checkout beside this repository (`PARROT_KIT_DIR`).
  - `GET /assist/windows` and `POST /assist/windows/focus`: apps and windows by most recent use, a revision counter, and a focus that answers what is true (`ok` only when the app or window is in front). Refused when the screen is locked or secure input is on, bounded in size, rate limited, one activation at a time. Window titles and names are never logged (counts only) and are masked in `GET /logs`.
  - `POST /assist/pointer/session` and a UDP pointer stream (TPT1): a session id and a datagram key per session over the authenticated route; every datagram carries a 16-byte HMAC-SHA256 tag and comes from the address that opened the session; sessions end after 30 s of silence, at the lock screen, on `assist off` and after an hour; the socket is bound to the tailnet address only (never a wildcard) and exists only while a session does; datagrams are rate limited and unauthenticated ones get no answer. Events go to a `PointerSink`; tests use a recording sink and never post a real pointer event.
  - Same tailnet-identity authorization as `POST /text`, except a caller that holds only the optional key is refused (403 `assist_need_same_user`).
  - `GET /status` reports `assist: {enabled, windows, pointer, capabilities}`. `greenfield-inserter assist [on|off|windows|focus|pointer|titles]` and `assist check-windows` (the live window check, from Terminal.app on the Mac).
  - `scripts/assist-live-pointer-test.sh`, DISABLED until the captain approves a scratch Mac or macOS VM, and `scripts/assist_tpt1_probe.py`, an independent TPT1 encoder checked against the kit's recorded datagrams by `make test`.

### Changed
- The daemon's main thread runs its run loop (NSWorkspace needs it to keep the application list current).

## [0.3.0] - 2026-10-21

### Added
- `GET /logs`: the daemon's own recent log, redacted, for this Mac and devices of its tailnet user (not the optional key), with
  limits (2000 lines, 256 KiB, 6 requests a minute) and `format=text` for curl. `greenfield-inserter logs` and `macs logs ALIAS`
  show the same page, `GET /status` reports `logs_available`, and `health`/`doctor` show a "Logs available" line. MINOR bump: the
  app and the daemon move to the 0.3 line together. See `docs/logs.md`.

### Changed
- Request logging keeps caller-controlled values (ids, source labels, unknown paths) to a shape that cannot carry text.

## [0.2.3] - 2026-10-20

### Added
- `GET /peers`: the other Macs of the same tailnet user that run the daemon (`{peers:[{name,address,version}]}`), so the phone
  needs only one seed; a Bonjour `_greenfield._tcp` advertisement carrying the tailnet address; the `greenfield://add` link and a
  terminal QR code (`greenfield-inserter link`, also shown by `make install`). Additive, so the 0.2 line stays compatible.

## [0.2.2] - 2026-10-20

### Fixed
- An Accessibility grant that arrives while the daemon is running was not usable until the daemon was relaunched, so pastes
  were dropped although `health` said "granted". Under launchd the daemon now exits when it sees the grant and `KeepAlive`
  restarts it; `health` also flags a grant that arrived after start ("restart needed") with the `restart` command.

## [0.2.1] - 2026-10-20

The daemon's first release on the 0.2 line (the phone branch tagged `v0.2.0` for the app; the rule keeps patch free, so the
two are compatible). Breaking from 0.1.x.

### Breaking
- Authorization is by tailnet identity: requests are accepted from this Mac, and from devices of the same tailnet user as
  this Mac's own node, as told by the local Tailscale; if Tailscale cannot say, the request is refused (503
  `identity_unavailable`). The per-Mac key is now optional, and having none is healthy.
- `POST /text` never claims an insert without evidence: the answer carries `delivery` (`confirmed` or `unconfirmed`), a paste
  that provably did not arrive is retried by typing, and a field that provably did not change gives 502 `not_delivered`.

### Added
- Semantic version from the git tags (`GET /status` `version`, `min_client_version`, `app_compatible`, `clients`, `build`),
  the compatibility rule with HTTP 426, and recorded sample files for the phone's contract tests.
- `health` and `doctor` end with "App compatible" and "Can actually insert text"; `doctor` runs a live `selftest`.
- `GET /status` carries the delivery line (`can_insert`, `delivery_message`, `delivery_fix`, `delivery`).
- `restart`, `update --from FILE` (installs a signed build, restarts, verifies the running build is the new file, rolls back
  if it does not come up), `verify-running`, `macs restart`, and a doctor check that the running build is the installed file
  and that launchd is not throttling a crash loop. `make install` does the same and prints the verified running version.
- `selftest` and `macs selftest`; `health`, `doctor`, `macs health`, `macs doctor`, `macs check`, `macs test`.

### Fixed
- The selftest window had no Edit menu, so macOS never delivered Cmd+V to it; this was reported as an insert that did
  not arrive although the daemon's paste worked.
- The Tailscale command-line wrapper is preferred over the app's own binary, which could not answer under launchd.
