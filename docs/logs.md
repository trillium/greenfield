# Logs: ask for them when something is not working

When something does not work you should not need a cable, a file manager or an ssh session to find out why. One command pulls the
recent log of the phone app, of each Mac's daemon and of the sound trainer into a private folder, and the phone can share its own
log from the Diagnostics screen.

```
make logs                                   # everything, the last 30 minutes
make logs TARGET=phone SINCE=2h             # only the phone, the last two hours
make logs TARGET=macbook,mini0 TAIL=1000    # two Macs, up to 1000 lines each
scripts/pull-logs.sh --list                 # the sources this project knows
```

`scripts/pull-logs.sh [--target phone|macbook|mini0|trainer|all] [--since 30m] [--tail N] [--out DIR]` prints one line per source
(how many lines, where the file is) and exits 0 only when every requested source was pulled. A source that cannot be pulled is named
with what to do about it (unlock the phone, wake the Mac, update the daemon).

## What is in the logs, and what never is
Every log line is an id, a count, a length, a time, a state or the text of an error. **Dictated text, keys and recordings are never
in a log.** That is built in, not hoped for:

- Nothing hands the dictated text to a logger. The phone logs "transcribed 41 characters in 321 ms"; the Mac daemon logs
  "text id=… sent chars=41 method=paste delivery=confirmed". The phone's outbox keeps the words so a failed send can be retried, so
  the support log reads the outbox's ids, states and timings and only the *length* of each text.
- A value that comes from a caller (an id, a source label, a path) is written to the daemon's log only in a shape that cannot carry
  text: a short id or label from a small alphabet, or the fixed word `(invalid)`, `other` or `(unknown)`.
- On the way out every line goes through the same redactor (`App/Sources/Support/LogRedactor.swift`, one file used by the app and by
  the daemon): header and field values for keys, tokens, passwords and cookies, `Bearer …`, well-known token shapes, `user:password@`
  in a URL and any long opaque string (a hash, a key) become `<redacted>`; ids stay; each entry is one line of at most 400
  characters. `scripts/pull-logs.sh` applies the same rules again to whatever it pulled.
- Tests feed text and secrets through the real loggers and read the answers back: `mac/Tests/InserterCoreTests/LogsTests.swift`
  (the daemon, with the real file logger and request handler), `App/Tests/SupportLogTests.swift` (the phone's event log and outbox),
  `App/Tests/LogRedactorTests.swift` and `scripts/test-pull-logs.sh` (the redactor and the pull script).

## The sources
| Target | What is pulled | How |
|---|---|---|
| `phone` | the app's support log: the Diagnostics events, the outbox's ids/states/timings/lengths, the Health summary | `devicectl device copy from` the app container (`Library/Application Support/support-log.txt`); the phone is found by name, nothing about it is stored in the repository. The phone must be awake and unlocked once. `LOGS_DEVICE=<id>` picks a phone by id. |
| `macbook`, `mini0` | that Mac's daemon log | `GET /logs` on its daemon, over the tailnet |
| `trainer` | the sound trainer's service log on mini0 | read from its log file |

The phone's raw `events.json` and `outbox.json` are not copied: the outbox holds the dictated text. The support log is written from
them without the text, a couple of seconds after any change and whenever Diagnostics is opened.

## Where the files go
`~/Library/Logs/greenfield-pulled/<date-time>/<target>.log`, a folder only you can read (mode 700, files 600). `--out DIR` chooses
another folder, but never one inside a git repository: the script refuses. Delete the folder when you are done with it.

## The daemon: `GET /logs`
The daemon on each Mac serves its own log (the file `~/.config/greenfield-inserter/inserter.log`, which `FileLogger` writes and
rotates) and the command line shows the same page:

```
greenfield-inserter logs --tail 100 --since 30m     # this Mac, works even with the daemon stopped
greenfield-inserter macs logs <alias> --tail 100    # another Mac, over the tailnet
curl 'http://<mac>:<port>/logs?tail=100&since=30m&format=text'
```
- **Who may ask.** The same tailnet-identity rule as everything else: this Mac itself and devices of this Mac's tailnet user. If
  Tailscale cannot say who is calling, the answer is 503 `identity_unavailable` (it fails closed). The optional key does *not* open
  `/logs` (403 `logs_need_same_user`): a device of another user may insert text, not read this Mac's history. There is no
  app-version gate on this route, so a Mac with a mismatched app still gives its logs.
- **Limits.** `tail` 1 to 2000 lines (default 200); `since` up to 7 days (`90s`, `30m`, `2h`, `1d`); at most 256 KiB in the answer
  (the oldest lines are dropped and `truncated` says so); at most 6 answered requests a minute for the whole daemon (429 with
  `Retry-After` after that). Unknown parameters are a 400, never ignored.
- **Answer.** JSON `{ok, name, version, generated_at, tail, since_s, count, bytes, truncated, lines[]}`, or with `format=text` the
  lines themselves (`X-Logs-Truncated`, `X-Logs-Count` headers). 404 `no_log` when there is no log file yet.
- `GET /status` says `logs_available` and `logs` (`route`, `max_lines`, `max_bytes`), and `health`/`doctor` show a **Logs available**
  line. A daemon without a readable log is a warning there; it does not make a Mac that delivers text unhealthy.

## On the phone: Share logs
Help > Diagnostics > **Share logs** opens the iOS share sheet with the same redacted file `make logs` pulls (AirDrop, Messages, Files,
Mail). The screen says what is in it. Copy the log in the menu copies the same text. Health shows **Logs available** (how many events
are kept) and warns if the file cannot be saved.

## Adding a source
`Config/logs.conf` lists the sources, one line each (`device`, `daemon`, `file` or `ssh`; the file explains the fields). The script is
the same in every project that uses it; only that file differs.

## Compatibility
`GET /logs` is a new route of the daemon, so it belongs to the contract in `docs/mac-contract.md` and the release that adds it bumps
MINOR (0.3.0): while MAJOR is 0 the app's MINOR and the daemon's MINOR must match, so the phone and every Mac are updated together.
An older daemon answers 404 and `make logs` says "update it".
