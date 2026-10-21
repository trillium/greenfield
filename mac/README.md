# greenfield-inserter

A small Mac agent that receives text over the tailnet and inserts it at the cursor of whatever
app is focused. The phone app is the first client; any other input source can use the same two
routes. Each Mac runs its own copy with its own key, so a client can switch between Macs.

## HTTP API

The port is `GREENFIELD_PORT` from `.env` (copy `.env.example` to `.env` first; `--port N` overrides it).
Every request needs the header `X-Dictation-Key: <key>`.

**Network policy.** Plain HTTP is used on purpose: the trust boundary is tailnet membership, plus the per-Mac
key. The daemon listens on this Mac's tailnet address (the `100.64.0.0/10` address Tailscale assigns) and on
loopback (`127.0.0.1`), and on no other interface (not the LAN, not `0.0.0.0`). It does not look at the `Host`
header, so a request addressed by the short MagicDNS name, the full `*.ts.net` name or the `100.x` address
all work. `GET /status` reports the addresses it is serving as `listen`, and `macs check` flags anything outside
the policy.

`GET /status` returns the Mac's `name` (hostname unless changed with `greenfield-inserter name set`),
the daemon `version`, `uptime_s`, `secure_input`, `screen_locked`, `accessibility` and `inserted_count`.

`POST /text` with a JSON body:

| field    | notes |
|----------|-------|
| `id`     | required, up to 128 characters; a retry with the same id is answered `200` with `"duplicate": true` and inserts nothing (also accepted as `X-Request-Id`) |
| `text`   | required, non-empty, up to 256 KiB |
| `method` | optional: `paste` or `type`; default is paste, falling back to typed key events if the paste cannot be set up |
| `source` | optional label for the log (`phone`, ...) |

| status | meaning |
|--------|---------|
| 200 | inserted (or a duplicate id) |
| 400 / 413 | bad body / text too large |
| 401 | missing or wrong key |
| 409 | secure input is on (a password field is focused); nothing inserted, retry later with the same id |
| 423 | the screen is locked; nothing inserted, retry later with the same id |
| 503 | no key set on this Mac, or Accessibility not granted |

Only successes are remembered for de-duplication (15 minutes, 1024 ids), so a refused request can be retried with the same id.

## Setup on a Mac

```
cp .env.example .env      # the port lives here (GREENFIELD_PORT); .env is gitignored
make -C mac test          # unit tests
make -C mac key           # create the key; it is shown once, enter it in the phone app
make -C mac install       # launchd agent: starts at login, restarts on crash
make -C mac permissions   # makes macOS show the Accessibility prompt
make -C mac run           # or run in the foreground instead of installing
```

The key is generated randomly; only its SHA-256 is stored, in `~/.config/greenfield-inserter/key`
(mode 0600, directory 0700), so it cannot be read back. `make key FORCE=--force` rotates it; the daemon
picks the change up without a restart. Set `GREENFIELD_INSERTER_HOME` to use another directory.

**Permission:** inserting needs Accessibility. Approve the macOS prompt "greenfield-inserter would like to
control this computer using accessibility features" (System Settings > Privacy & Security > Accessibility).
macOS ties the grant to the installed binary (`~/.local/share/greenfield-inserter/greenfield-inserter`), so
re-approve after `make install` replaces it with a rebuilt one.

## Checking several Macs from one place

On the Mac you sit at (or any machine on the tailnet), remember each Mac once, then check them all:

```
greenfield-inserter macs add mini0 mini0.<tailnet>.ts.net      # asks for the key without echo
greenfield-inserter macs add macbook macbook.<tailnet>.ts.net
make -C mac check                       # GET /status on every Mac: name, version, ready / locked / secure-input / needs approval / unreachable
make -C mac insert-test MAC=macbook     # types a harmless "greenfield test <time>" into that Mac's focused app
```

`check` also prints each Mac's listening addresses with a policy verdict (tailnet and loopback only). It exits
non-zero when a Mac is unreachable, rejects the key, lacks Accessibility, or listens outside the policy; locked and
secure-input are reported but are normal. Keys for remembered Macs live in `macs.json` (mode 0600) beside the
daemon's own files; `macs show-key ALIAS` prints one when you need to enter it into the phone app.
`key create --out-file PATH` writes a new key to a 0600 file instead of the terminal, for setting up a Mac over ssh
without the key passing through the session: `ssh mac 'greenfield-inserter key create --out-file k'`, then pipe
the file into `macs add ... --key-stdin` and delete it.

## Logs

`~/.config/greenfield-inserter/inserter.log` (rotated at 2 MB) records start-up, requests, status codes,
request ids, the source label, character counts and the insertion method. It never records inserted text
or keys.

## Development

`swift test` runs the request-handling, HTTP parsing, key store and de-duplication tests. The `testfield`
target is a window with a text view that mirrors its contents to a file, for checking insertion end to end:
`swift run testfield --out /tmp/field.txt`.
