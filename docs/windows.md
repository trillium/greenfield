# Greenfield on Windows: the input daemon

`windows/` is the Windows twin of the Mac daemon (`mac/`, `greenfield-inserter`). It speaks the same contract on the same port, so **the phone needs no change**: a Windows computer on your tailnet appears in Computers like a Mac, shows Ready, and takes dictated text at the cursor of the focused app.

> **Not yet run on a real Windows computer.** Everything below that says "works" means "written to the contract and proven by tests with a fake Windows". The parts that need a real Windows (typing with `SendInput`, reading a field back, the lock-screen and password-box checks, the firewall, local-network discovery) have only been compiled (`GOOS=windows`, amd64 and arm64) and reviewed, never executed. [Testing it on a real computer](#test-it-on-a-real-windows-computer-checklist) is a short list of commands at the end of this page; until someone has done it, treat the Windows daemon as a prototype.

## What it is

- One static file, `greenfield-inserter.exe` (Go, no cgo, no third-party modules), for `windows/amd64` and `windows/arm64`.
- It listens on `GREENFIELD_PORT` (default in `.env.example`, 47821) on this computer's tailnet address and on loopback, and nowhere else.
- It types the text with the Win32 `SendInput` API: each character as a Unicode key event (`KEYEVENTF_UNICODE`, so any language and emoji work whatever the keyboard layout), and **every line break as a real Return key press**, so line breaks, empty lines and a trailing newline are kept exactly as on the Mac. There is no clipboard involved; your clipboard is never touched.
- Trust is the tailnet. For each request it asks the local Tailscale (`tailscale whois --json <caller address>`) who owns the caller, and accepts the caller only if that device belongs to the **same tailnet user as this computer's own node**, or is this computer itself (loopback). If Tailscale cannot say, it refuses (HTTP 503 `identity_unavailable`: it fails closed). There is no key, no password and nothing to configure. Unlike the Mac daemon it has **no optional key** at all; a request that offers one and is not otherwise allowed gets 401. (A browser outside the tailnet can be paired instead, with a one-time code from `greenfield-inserter pair` and a short-lived token that only sends text: `docs/pwa.md`. It is the same book, routes and limits as on the Mac, and every request without a token is judged by tailnet identity exactly as before.)
- Discovery is automatic, as on the Mac: `GET /peers` lists the other computers of your tailnet user that run the daemon (Macs and Windows computers), it advertises `_greenfield._tcp` on the local network (Bonjour/mDNS) with the same four TXT records (`name`, `address`, `version`, `path`), and `greenfield-inserter link` prints the `greenfield://add?...` link.

## Contract parity matrix

The contract is `docs/mac-contract.md` (the phone's side) and `mac/docs/contract.md` (the daemon's side). "Same" means the same route, JSON field names and types, status codes and error codes; the tests check it against the Mac daemon's and the phone's recorded samples (see [Tests](#tests)).

| Contract item | Mac daemon | Windows daemon | Notes |
|---|---|---|---|
| `POST /text` (`id`, `text`, `source`, optional `method`) | yes | **same** | up to 256 KiB, CRLF/CR/NEL/LS/PS become one line feed, empty lines and a trailing newline kept, `id` up to 128 chars, a repeat of an `id` is `200` with `"duplicate": true` and types nothing (15 minutes, 1024 ids) |
| `POST /text` answer | `ok, id, chars, method, delivery` | **same** | `method` is always `type` (`"paste"` is accepted and answered as `type`: there is no paste on Windows). `chars` counts Unicode characters, not grapheme clusters |
| Line breaks | a Return key press each | **same** | `SendInput` with `VK_RETURN`, never a newline inside a typed string |
| `GET /status` | yes | **same**, plus `platform: "windows"` | every field the Mac reports is present with the same JSON type (checked against `mac/Tests/Fixtures/status-ready.json`) |
| `GET /health` (this computer only) | yes | **same** | `pid`, `executable`; 403 `local_only` from anywhere else |
| `GET /peers` | macOS peers | **Mac and Windows peers** | probes each online same-user node whose OS is `macOS` or `windows`; cached 20 s |
| `GET /logs` | yes | **same** | 2000 lines, 256 KiB, 6 requests a minute, `format=text`, `since`, redacted, no app-version gate, 403 for a key |
| Tailnet-identity trust | `tailscale whois` | **same** | the CLI is looked up on `PATH` and in `C:\Program Files\Tailscale` |
| Optional key (`X-Dictation-Key`) | yes | **no**, by design | `key_configured` is always `false`; the phone never needs one |
| Version rule, `X-Greenfield-App`, HTTP 426 | yes | **same** | the oldest app accepted is the Mac daemon's `mac/min-client-version` (a test keeps the two equal) |
| `409 secure_input` | Secure Event Input | **best effort** | detects a standard Win32 password box (`ES_PASSWORD`) with the keyboard. Browsers and other toolkits draw their own password fields and are **not** detected |
| `423 screen_locked` | session dictionary | **same answer, different test** | the input desktop cannot be opened: lock screen, UAC prompt, disconnected remote session |
| `503 accessibility_not_granted` | Accessibility permission | **different meaning** | Windows has no permission to grant. It means the app in front **runs as administrator**, and Windows silently drops a normal program's keys for such apps (UIPI). `accessibility` in `/status` is `false` then, and the text is refused instead of lost. The look at the app in front is a heuristic (it asks Windows whether that process is more privileged than this one); if it ever refuses a normal app, `serve --no-admin-check` turns it off |
| `delivery: confirmed` | reads the focused field through Accessibility | **only for Edit/RichEdit controls** | reads the focused control with `WM_GETTEXT` before and after (Notepad's classic edit, many dialogs). Anywhere else (browsers, Word, terminals, most modern apps) the answer is `unconfirmed`, never a guess |
| `502 not_delivered` | field readable and unchanged | **implemented, off by default** | a readable field that did not change is reported `unconfirmed` for now, because the read-back of a foreign window is unproven on a real computer and a false 502 would make the phone resend text that did arrive. Flip `StrictUnchanged` (`windows/internal/winsys`) once the checklist shows the read-back is reliable |
| `can_insert` / `delivery` evidence | real delivery or selftest | **same** | `GET /status` says `can_insert: false` until a confirmed delivery or a passing selftest since the daemon started |
| `/assist/windows`, `/assist/windows/focus`, `/assist/pointer/session` | opt-in tools | **not supported** | answered `404 assist_off` ("not supported on this computer") after the same authorization and version checks; `/status` says `assist: {enabled: false, windows: false, pointer: false, capabilities: []}`, so the phone hides the Assist tab. **No pointer or window control is implemented** |
| Bonjour `_greenfield._tcp` | `NetService` | **own small mDNS responder** | same TXT records; the record carries the tailnet name because the daemon is not on the LAN itself |
| `greenfield://add` link | `link` (+ QR) | `link` (no QR) | follow-up |
| `health`, `doctor`, `ready`, `selftest` | yes | **equivalents** | `health`: yes/no; `doctor`: why and fix, then the live test when only proof is missing; `ready`: ready or one next step; `selftest`: opens a small window, types two strings through the real daemon, reads them back |
| `logs`, `name`, `port`, `version` | yes | **same** | `.env`/`GREENFIELD_PORT`/`--port` as everywhere |
| `macs ...` (remember and check other computers) | yes | no | a Mac does the checking of Windows computers over HTTP (`curl .../status`) |
| `restart`, `update`, `verify-running`, launchd agent | yes | no | autostart and updates are follow-ups |
| `permissions` | opens the Accessibility prompt | prints that there is nothing to approve | |
| `install.sh` onboarding | yes | no | installers and code signing are follow-ups |

## Build

On any machine with Go (`brew install go`):

```
make windows        # gofmt, go vet (native, windows/amd64, windows/arm64), the tests, then the two .exe files
ls build/windows/   # greenfield-inserter-windows-amd64.exe, greenfield-inserter-windows-arm64.exe
```

`make check` includes it. The version is stamped from the git tags (`scripts/version.sh`), the oldest accepted app from `mac/min-client-version`. A plain `go build` produces version `0.0.0`, which the phone reports as "update the computer's daemon" and `health` warns about.

Try the connection from the phone without a Windows computer, on a Mac or Linux box: `make -C windows run` starts the daemon with `--dry-run` (it answers everything and types nothing).

## Using it

```
greenfield-inserter.exe serve            # run the daemon; leave the window open (Ctrl+C stops it)
greenfield-inserter.exe ready            # "ready", or exactly one next step
greenfield-inserter.exe doctor           # what is wrong, why it matters, the exact fix
greenfield-inserter.exe selftest         # proves text arrives (a small window opens for a few seconds: do not type)
greenfield-inserter.exe firewall         # shows the one firewall rule; `firewall add` (administrator terminal) adds it
greenfield-inserter.exe link             # the greenfield://add link for the phone
greenfield-inserter.exe logs --tail 100  # recent log, redacted
greenfield-inserter.exe name set "Desk PC"
```

Files live in `%AppData%\greenfield-inserter` (`GREENFIELD_INSERTER_HOME` overrides): `inserter.log` (rotated at 2 MB), `clients.json`, `delivery.json`, `name`. The log holds ids, counts, lengths, timings, states and error text only; never dictated text.

**Run it in your own desktop session** (a terminal you opened, or a shortcut), not as a Windows service: `SendInput` only reaches the desktop of the session it runs in.

**Windows Firewall.** It blocks inbound connections to a program until a rule allows them, and Tailscale's network is normally classed public. The phone would simply time out. `greenfield-inserter.exe firewall add`, from a terminal opened as administrator, adds one rule: TCP, this port, only from `100.64.0.0/10` (the tailnet), any profile. `firewall remove` deletes it. `doctor` says if the rule is missing.

**Unsigned.** The `.exe` is not code-signed, so SmartScreen shows "Windows protected your PC": More info, Run anyway.

## What it cannot do (known limits)

- Type into an app running as administrator (Windows blocks it for any normal program). The daemon says so (`503 accessibility_not_granted` with the reason) instead of dropping the text. Running the daemon as administrator too lifts it, at the usual cost of running as administrator.
- Recognise password fields other than standard Win32 password boxes. A dictation can land in a browser's password field; the Mac cannot be fooled this way because macOS tells it.
- Confirm delivery outside Edit/RichEdit controls (it says `unconfirmed`).
- Type at the lock screen or a UAC prompt (it says `423 screen_locked`).
- The window switcher and the trackpad (Assist): not supported, by decision.
- Listen on more than the tailnet and loopback, or serve other users: a computer with several Windows users runs one daemon per user in that user's session, each on its own port (`--port`); the phone's computer entry says which.

## Follow-ups (out of scope for this change)

- A QR code in `link`.
- Autostart at sign-in, update/restart commands, an installer and Authenticode signing (no SmartScreen warning).
- `make logs TARGET=<windows computer>` (`scripts/pull-logs.sh` is shared with the sibling repository, so that is a change in both).
- The Mac daemon's `GET /peers` only probes `macOS` nodes, so a Mac seed does not list Windows computers; a one-line change to include `windows` there. (A Windows seed lists both, and the local-network discovery finds both.)
- A Windows password-field check that also sees browsers (UI Automation `IsPassword`), and UI Automation read-back so more apps can be `confirmed`.
- Linux.

## Tests

`make -C windows test` (part of `make windows` and `make check`) runs on any machine; nothing in it needs Windows or a keyboard:

- **Contract**, `windows/internal/server/contract_test.go`: the phone's recorded requests (`App/Tests/Fixtures/request-*.json`) are fed to the daemon and must be accepted, with the multi-line sample typed with every line break kept; every field of the Mac daemon's recorded answers (`mac/Tests/Fixtures/status-*.json`, `peers-*.json`) must be present here with the same type; every error code of the contract is produced with the status the phone maps it to; this daemon's own recorded answers are in `windows/testdata/` (`RECORD_FIXTURES=1 go test ./internal/server -run TestRecordedAnswers` re-records them).
- **Routes and rules**, `handler_test.go`: authorization (same user, other user, tagged, unknown, loopback, a key never opens the door, the socket and not a header decides "loopback"), every status and error code of `/text`, `/status`, `/health`, `/peers`, `/logs`, the version rule, de-duplication, the assist routes, and that no dictated text or caller-controlled string reaches the log.
- **Typing plan**, `windows/internal/inserter`, `windows/internal/winsys/layout_test.go`: line endings, one Return per line break, surrogate pairs in order, the `INPUT` record layout (40 bytes, as `SendInput` requires), batches that never split a key down from its key up, what a read-back proves.
- **Identity and discovery**, `windows/internal/tailnet`: `tailscale whois` and `status` parsing with a fake tool, the caching and fail-closed rules, which peers are probed, the add link.
- **The rest**: the log source, rate limiter and redactor, the stores, `.env` and port precedence (and that the default equals `.env.example`), the mDNS packets (decoded with an independent parser), the listeners (waiting for Tailscale, following an address change), health/doctor/ready, the selftest with a fake window and daemon, and the command line.
- `GOOS=windows GOARCH=amd64|arm64 go vet ./...` compiles every Win32 call for both targets.

On a Mac with Tailscale the daemon was also run natively with `--dry-run` and answered `/status`, `/text`, `/peers` and `/logs` to `curl` over the tailnet address, with the real `tailscale whois` deciding who may call. That proves the contract and the identity path, not typing.

## Test it on a real Windows computer (checklist)

You need a Windows 10/11 computer (x64, or Arm: `systeminfo | findstr /C:"System Type"`) signed in to **the same Tailscale user as your phone**, and a Mac with this repository. About 15 minutes.

1. **Build and copy.** On the Mac:
   ```
   make windows
   tailscale file cp build/windows/greenfield-inserter-windows-amd64.exe <windows-computer-name>:     # arm64 for Windows on Arm
   ```
   On the Windows computer, in PowerShell:
   ```
   mkdir $HOME\greenfield; cd $HOME\greenfield
   tailscale file get .                      # saves the file; rename it:
   ren greenfield-inserter-windows-amd64.exe greenfield-inserter.exe
   .\greenfield-inserter.exe version         # expect 0.4.x and windows/amd64 (SmartScreen: More info, Run anyway)
   ```
2. **Before starting it.** `.\greenfield-inserter.exe doctor` should fail only on "Daemon running" and (if you have not added it) the firewall; "Tailscale command-line tool found" should pass. If it does not, tailscale.exe is not on the PATH and not in `C:\Program Files\Tailscale`: tell me where it is.
3. **Firewall.** Open a second PowerShell as administrator (right-click, Run as administrator):
   ```
   cd $HOME\greenfield
   .\greenfield-inserter.exe firewall add       # prints the rule name; `netsh advfirewall firewall show rule name=all | findstr Greenfield` shows it
   ```
4. **Start it.** In the normal (non-administrator) PowerShell: `.\greenfield-inserter.exe serve --log-stderr`. Leave it open. If Windows asks to allow the program through the firewall, either answer is fine (the rule above covers the tailnet).
5. **Self-check.** In a third PowerShell:
   ```
   .\greenfield-inserter.exe ready      # expect: not ready, next step = run selftest
   .\greenfield-inserter.exe selftest   # a small window opens; DO NOT TYPE or click away. Expect PASS
   .\greenfield-inserter.exe ready      # expect: ready
   .\greenfield-inserter.exe doctor     # expect: all good
   ```
   If the selftest fails, copy its FAIL block; it names the step (window, focus, send, line breaks) and the fix.
6. **From the Mac.** (`<pc>` is the computer's name from `tailscale status`; port 47821 unless you changed `GREENFIELD_PORT`.)
   ```
   curl -s http://<pc>.<tailnet>.ts.net:47821/status | python3 -m json.tool     # "platform": "windows", "can_insert": true, "tailnet_user": your login
   curl -s http://<pc>.<tailnet>.ts.net:47821/peers
   dns-sd -B _greenfield._tcp                    # the Windows computer's name should appear within ~10 s (local-network discovery; Ctrl+C to stop)
   curl -s -X POST http://<pc>.<tailnet>.ts.net:47821/text -H 'Content-Type: application/json' \
        -d '{"id":"win-test-1","text":"hello from the mac\nsecond line\n","source":"curl"}'
   ```
   Before the last command, click into Notepad on the Windows computer. Expect "hello from the mac" and "second line" on two lines, the cursor on a third. Run the same command again: it answers `"duplicate": true` and types nothing.
7. **From the phone.** Computers tab: the Windows computer should show up under discovered computers by itself (or `.\greenfield-inserter.exe link` and open the link on the phone). Select it. The dot should be green ("Ready"). Dictate a sentence, then one with a line break, with Notepad focused: the text appears, line breaks are Return presses. Try Word or a browser text box too.
8. **Refusals** (each should leave the document untouched and show a plain reason on the phone):
   - Lock the screen (Win+L) and send: `423 screen_locked`.
   - Open Notepad **as administrator**, focus it, send: `503 accessibility_not_granted` with the administrator explanation (`GET /status` shows `"accessibility": false`).
   - Focus a classic password box (for example Credential Manager, "Add a Windows credential"), send: `409 secure_input`. Then a browser password field: *not* detected (known limit); note what happens.
9. **Delivery evidence.** Send text into Notepad, then `curl .../status` and look at `delivery_message`: "by a real delivery" means `WM_GETTEXT` read-back works for that app; "unconfirmed" in the `/text` answer for Notepad means it does not (report which Windows and Notepad version). Do the same with a browser text box (expect `unconfirmed`).
10. **Report back** (paste into the task): which steps passed; the FAIL blocks; `.\greenfield-inserter.exe logs --tail 200` (redacted, safe to share); Windows version and architecture; whether the phone found the computer by itself (step 7) and whether `dns-sd` saw it (step 6).
11. **Clean up.** Ctrl+C in the serve window. In the administrator PowerShell: `.\greenfield-inserter.exe firewall remove`. Delete `$HOME\greenfield` and, if you want, `%AppData%\greenfield-inserter`.

The things most likely to need a fix after the first real run, in this order: the firewall step, `tailscale.exe` lookup, the lock-screen test, the administrator check (if a *normal* app is refused as administrator, say which app; `serve --no-admin-check` is the workaround), the read-back in step 9, and local-network discovery.
