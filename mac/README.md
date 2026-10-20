# greenfield-inserter

A small Mac agent that receives text over the tailnet and inserts it at the cursor of whatever
app is focused. The phone app is the first client; any other input source can use the same two
routes. Each Mac runs its own copy, and a client can switch between Macs. Nothing needs configuring on
the phone: no key is typed per computer.

## HTTP API

Port `47821`.

**Who may call (authorization).** The trust boundary is tailnet membership. For each request the daemon asks the
local Tailscale (`tailscale whois`) who owns the caller's address and accepts it only if that device belongs to the
**same tailnet user as this Mac's own node**. Requests from this Mac itself (loopback) are also accepted. If Tailscale
cannot say who is calling, the request is refused (HTTP 503 `identity_unavailable`): it fails closed. Tagged devices and
devices of other users are refused (401). An **optional key** (`greenfield-inserter key create`) is a second way in for
devices of other users, sent as `X-Dictation-Key`; having no key set is normal and healthy. `GET /status` reports
`"auth": "tailnet"`, `tailnet_user` and whether `key_configured`.

**Network policy.** Plain HTTP is used on purpose. The daemon listens on this Mac's tailnet address (the
`100.64.0.0/10` address Tailscale assigns) and on loopback (`127.0.0.1`), and on no other interface (not the LAN, not
`0.0.0.0`). It does not look at the `Host` header, so a request addressed by the short MagicDNS name, the full
`*.ts.net` name or the `100.x` address all work. `GET /status` reports the addresses it serves as `listen`, and
`macs check` flags anything outside the policy.

`GET /status` returns the Mac's `name` (hostname unless changed with `greenfield-inserter name set`), the daemon
`version`, `auth`, `uptime_s`, `secure_input`, `screen_locked`, `accessibility`, `inserted_count`, `listen`, and the
delivery line: `can_insert` (true only when text was recently read back from a real field), `delivery_message`,
`delivery_fix`, the same inside a `delivery` object `{ok, can_insert, state, message, text, fix, at, source}`, and the
raw `evidence`. `GET /health` is the same plus `pid`/`executable` but answers only requests from this Mac.

`POST /text` with a JSON body:

| field    | notes |
|----------|-------|
| `id`     | required, up to 128 characters; a retry with the same id is answered `200` with `"duplicate": true` and inserts nothing (also accepted as `X-Request-Id`) |
| `text`   | required, non-empty, up to 256 KiB. A bare newline (with `"method": "type"`) is a Return key press |
| `method` | optional: `paste` or `type`; default is paste, retried by typing if the paste provably did not arrive |
| `source` | optional label for the log (`phone`, ...) |

| status | meaning |
|--------|---------|
| 200 | sent; `delivery` is `confirmed` (the focused field was read back and now holds the text) or `unconfirmed` (keys were sent but the target does not expose its text, e.g. a terminal, or it was a key press) |
| 400 / 413 | bad body / text too large |
| 401 | the caller is a device of a different tailnet user (or a wrong key) |
| 409 | secure input is on (a password field is focused); nothing inserted, retry later with the same id |
| 423 | the screen is locked; nothing inserted, retry later with the same id |
| 502 | `not_delivered`: the keys were sent but the focused field provably did not change; nothing was inserted |
| 503 | Accessibility not granted, or `identity_unavailable` (Tailscale could not identify the caller) |

The daemon never says it inserted something without evidence: it reads the focused field through Accessibility before and
after, and reports `unconfirmed` rather than `confirmed` when it cannot see the text. Only successes are remembered for
de-duplication (15 minutes, 1024 ids), so a refused request can be retried with the same id.

## Setup on a Mac

```
make -C mac test          # unit tests
make -C mac key           # OPTIONAL: a key for devices of other tailnet users (shown once)
make -C mac install       # launchd agent: starts at login, restarts on crash
make -C mac permissions   # makes macOS show the Accessibility prompt
make -C mac run           # or run in the foreground instead of installing
```

**The key file is not the key.** `~/.config/greenfield-inserter/key` holds only a hash of the key, so sending its
contents as `X-Dictation-Key` is refused with 401. The real key was shown once by `key create` and is kept by the
Mac that ran `macs add` (`greenfield-inserter macs show-key ALIAS` there). `health` and `doctor` say this too.

The optional key is generated randomly; only its SHA-256 is stored, in `~/.config/greenfield-inserter/key`
(mode 0600, directory 0700), so it cannot be read back. `make key FORCE=--force` rotates it; the daemon
picks the change up without a restart. Set `GREENFIELD_INSERTER_HOME` to use another directory.

**Permission:** inserting needs Accessibility. Approve the macOS prompt "greenfield-inserter would like to
control this computer using accessibility features" (System Settings > Privacy & Security > Accessibility).
macOS ties the grant to the installed binary (`~/.local/share/greenfield-inserter/greenfield-inserter`), so
re-approve after `make install` replaces it with a rebuilt one.

## Checking several Macs from one place

On the Mac you sit at (or any machine on the tailnet), remember each Mac once, then check them all:

```
greenfield-inserter macs add mini0 mini0.<tailnet>.ts.net      # no key needed for your own devices
greenfield-inserter macs add macbook macbook.<tailnet>.ts.net
make -C mac check                       # GET /status on every Mac: name, version, ready / locked / secure-input / needs approval / unreachable
make -C mac insert-test MAC=macbook     # types a harmless "greenfield test <time>" into that Mac's focused app
```

`check` also prints each Mac's listening addresses with a policy verdict (tailnet and loopback only). It exits
non-zero when a Mac is unreachable, refuses this device, lacks Accessibility, or listens outside the policy; locked and
secure-input are reported but are normal. Remembered Macs live in `macs.json` (mode 0600) beside the daemon's own
files. A key is only for the optional case of a device owned by a different tailnet user: `macs add ALIAS HOST --key`
(hidden prompt) or `--key-stdin` saves one, `macs show-key ALIAS` prints it. `key create --out-file PATH` writes a new key
to a 0600 file instead of the terminal, for setting one up over ssh without it passing through the session.

## Health and doctor

```
greenfield-inserter health          # this Mac: fast yes/no, exit 0 only if everything is good
greenfield-inserter doctor          # this Mac: for each failed check, what is wrong, why it matters, the exact fix
greenfield-inserter macs health     # the same for every remembered Mac, as seen from here
greenfield-inserter macs doctor
make -C mac health                  # (or doctor)
```

Both work over ssh (use the full path `~/.local/share/greenfield-inserter/greenfield-inserter`). `health` checks: daemon
running, listening on the tailnet address and loopback only, authorization by tailnet identity working (a key is not
needed), Accessibility granted, screen not locked, no secure input, version, and last of all **Can actually insert
text**: evidence that text really arrived, either a real delivery the daemon read back from the focused field or a
passing `selftest`, recorded since the daemon started (it expires after a week). With no evidence yet, `health` fails
and says to run `selftest`; `doctor` runs that live test for you (it opens a small window for a few seconds) when
everything else is fine (`doctor --no-selftest` skips it). `doctor` adds the launchd agent file and whether it is loaded and running, the binary
path (the Accessibility approval belongs to it), key file and directory permissions, a tailnet address, whether
the running daemon is the installed binary, and whether each remembered Mac is reachable from here. Locally these ask the daemon's loopback-only `GET /health` (no key, 403 to
anyone off the Mac); for remembered Macs they use `GET /status` with the saved key. Keys are never printed.

## Selftest

```
greenfield-inserter selftest             # on the Mac itself, no phone needed (make -C mac selftest)
greenfield-inserter macs ssh macbook user@macbook.<tailnet>.ts.net     # once
greenfield-inserter macs selftest macbook                              # from another Mac, over ssh
```

It opens a small window with a focused text field, sends a unique harmless string through the real daemon on
loopback (`POST /text`, the paste path), reads the field back to prove arrival, then sends a Return key press
(typed key event) and checks the field received it. It closes the window and prints PASS, or FAIL naming the
step with what is wrong, why and the fix (the preflight reuses the `doctor` checks). The window takes the
keyboard focus for a few seconds, so do not type while it runs.

It talks to the daemon over loopback, which is always allowed, so it needs no credential. A pass or a delivery
failure is written to the delivery ledger (`delivery.json`, mode 0600) that `health` and `GET /status` report
from. The window has an Edit menu with Paste, because macOS only routes Cmd+V to a text field through one.
`--simulate-delivery` skips the daemon and only exercises the
window; its output is labelled SIMULATED and its exit code is always non-zero.

## Keeping the Accessibility approval across rebuilds

`make install` signs the binary ad-hoc by default. An ad-hoc signature is tied to the exact build, so every
rebuilt and reinstalled binary needs the Accessibility approval again. Signing with a development certificate
instead gives the binary a designated requirement of its identifier plus the certificate (not the build), which
macOS keeps matching across rebuilds: `SIGN_IDENTITY="Apple Development: <name> (<id>)" make -C mac install`.
The signing must run where the certificate's private key is available and unlocked (a terminal on that Mac's
desktop, not a plain ssh session).

## Logs

`~/.config/greenfield-inserter/inserter.log` (rotated at 2 MB) records start-up, requests, status codes,
request ids, the source label, character counts and the insertion method. It never records inserted text
or keys.

## Development

`swift test` runs the request-handling, HTTP parsing, key store and de-duplication tests. The `testfield`
target is a window with a text view that mirrors its contents to a file, for checking insertion end to end:
`swift run testfield --out /tmp/field.txt`.
