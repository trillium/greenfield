# Changelog (greenfield-inserter, the Mac daemon)

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: `docs/versioning.md`. The repository has one
version line; entries here are the daemon's part of each release.

## [0.3.0] - unreleased

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
