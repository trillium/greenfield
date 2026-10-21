# The assist tools on the Mac: window switcher and trackpad

The daemon is the Mac's helper for the phone's two assist tools. The contract (routes, fields, the TPT1 wire) is the kit's:
`docs/assist.md` and `Tests/Fixtures/assist/` in the shared kit (`KitAssist`); this daemon builds against those types and tests against
those recorded files. This page is what is specific to the daemon: what is on, who may use it, what it refuses, and the live test that
has not been done.

## Off until you turn it on

Everything is **off by default**. `GET /assist/windows` and the other routes answer 404 `assist_off` and the phone hides the tools.

```
greenfield-inserter assist                 what is on
greenfield-inserter assist on | off        the master switch: the kill switch
greenfield-inserter assist windows on|off  the window switcher (list and focus), when the master switch is on
greenfield-inserter assist focus on|off    off leaves the list read-only; every focus is answered `denied`
greenfield-inserter assist titles on|off   off lists apps and windows without their titles
greenfield-inserter assist pointer on|off  the trackpad; off until turned on here, even when the master switch is on
```

The settings live in `~/.config/greenfield-inserter/assist.json` (mode 0600) and are read again on every request, so **`assist off` takes
effect at once without a restart**: the next request is refused with 404 and every pointer session is closed within a quarter of a second.
A missing, unreadable or malformed file means everything off. The phone cannot change any of it; it can only ask.

`GET /status` reports it as `assist: {enabled, windows, pointer, capabilities}`. `enabled` is the master switch; `windows` and `pointer` mean
"the tool's routes answer right now" (so each is false while the master switch is off); `capabilities` lists `windowTitles` and whatever the
pointer sink renders. An older daemon has no `assist` field: the phone treats that as "no assist tools".

## Who may use it

The same tailnet-identity check as `POST /text`, with one stricter rule: **a caller that only holds the optional key is refused** (403
`assist_need_same_user`). These tools act on this Mac, so they are for this Mac itself and for devices of its own tailnet user. A device of
another user (401) or one Tailscale cannot identify (503) never gets further. The `X-Greenfield-App` version rule applies (426).

## Window switcher

`GET /assist/windows[?since=&epoch=]` and `POST /assist/windows/focus`, exactly as the kit describes them. What the daemon adds:

| Rule | Behaviour |
|---|---|
| Locked screen | the list is `locked: true` with application names only (no windows, no titles); a focus is answered `locked`. Nothing wakes or unlocks the Mac |
| Secure input (a password field) | the list is refused with 409 `secure_input`; a focus is answered `denied` with the reason |
| Truth, not acknowledgement | after asking the system, the daemon looks again for up to 0.8 s and answers `ok` only if that app or window is in front; `declined` if nothing moved, `pending` if the front moved elsewhere |
| Gone is gone | a window or app id that no longer exists is `notFound`; a similar one is never substituted. `previous` is resolved on the Mac's own most-recently-used order |
| Order and `rev` | most recently used first, from the fronts it has seen; `rev` counts up only when something visible changed; `epoch` names one run of the daemon |
| Limits | body at most 1024 bytes (413); 10 requests a second, burst 20, and one activation in flight (429 with `Retry-After`); at most 200 apps, 64 windows per app, 600 windows, 240 characters per title, 40 000 title characters in all |
| Logging | **counts and results only**: `assist windows list apps=N windows=M rev=R`, `assist windows focus action=window result=ok`. No title, no app name, no bundle id, no window id is written. `GET /logs` also masks any `title=` or `app_name=` value that ever reached a line |
| Titles | passed on as the system gives them (the phone cleans them: `DisplayText.clean`), bounded in length. `assist titles off` keeps them on the Mac |

The real provider uses `NSWorkspace` and the Accessibility API (`MacWindowProvider`): ordinary apps only, a 0.25 s messaging timeout per app
(an app that does not answer is listed `unresponsive`, without windows), `denied` for every app while Accessibility is not granted. Window
ids are `w-<n>`, kept while the system hands back an equal element for the window. Windows on other desktops are not listed
(`otherSpaceWindows` is absent). The daemon's main thread runs its run loop, which NSWorkspace needs to stay current.

## Trackpad: the pointer session

An unauthenticated UDP port would let any device on the tailnet move the cursor, so the datagram path is not trusted at all. A datagram
moves the cursor only if it passes every step of this chain:

1. **Handshake over the authenticated HTTP route.** `POST /assist/pointer/session` (same identity rule as above, body ignored, at most 1024
   bytes) returns, for this caller only:
   ```json
   { "ok": true, "format": 1, "session": 16909060, "key": "<base64, 32 random bytes>",
     "tag": { "algorithm": "hmac-sha256", "length": 16 },
     "udp": { "address": "100.x.y.z", "port": 47821 }, "idle_timeout_s": 30, "max_lifetime_s": 3600, "capabilities": 0 }
   ```
   `session` is a random non-zero 32-bit id and `key` a fresh random key, per session. Neither is ever logged or written to disk. Refused with
   423 `screen_locked` on a locked screen, 429 `rate_limited` (3 opens at once, then one every 5 seconds), 429 `too_many_sessions` (at most 4 at
   a time), 503 `no_listener` when there is no tailnet address. A new session by the same caller replaces its old one.
2. **The sender's address** must be the address that opened the session. A datagram from anywhere else is dropped.
3. **The tag.** Every datagram ends with 16 bytes: the first 16 bytes of HMAC-SHA256 over everything before them, keyed with the session key
   (the kit's `TPT1Authenticator` hook). It is checked before anything else is parsed, in constant time. The daemon's replies carry the same
   kind of tag, with the same key. A datagram with no tag, a wrong tag, another session's key, or a changed byte is dropped **without any
   answer**: nothing is ever sent to an unauthenticated sender.
   Known answer for a phone to check its own code: key = the 32 bytes `00 01 02 ... 1f`; datagram = the 18-byte BYE header
   `54505431 05 00 01020304 00000001 00000000`; tag = `97b9dada3fe4445daeb8aee2ce65ff2d` (the daemon's tests and `scripts/assist_tpt1_probe.py
   --selftest` compute it independently).
4. **The kit's strict codec, then its sequence rules.** A replay, a late datagram or a packet that is not newer than the last one is dropped.
   The kit's recorded datagrams and its list of datagrams that must be rejected are both run through this chain in the tests.
5. **A rate limit** of 240 datagrams a second per session (burst 480); the rest are dropped.

A session ends, and everything it held is released, when: **30 seconds** pass without a valid datagram (a phone that is only waiting sends a
HELLO now and then); an hour has passed since it opened; the phone says BYE; the **screen locks**; **`assist off`** or `assist pointer off`
is run; the same caller opens another. A held button is also released after one second of silence (the kit's dead-man).

**The socket.** The UDP socket is opened only while at least one session exists and is closed when the last one ends, so with no session
the Mac has no pointer port open at all. It is bound to **one address**: the tailnet address (or `--bind`), never a wildcard (`0.0.0.0` is
refused in code and in a test). The port number is the HTTP port's. Counts of dropped datagrams by reason (`malformed`, `unknownSession`,
`wrongSource`, `authentication`, `rateLimited`, `rejected`) are logged every ten seconds while a session is open, as counts only.

**The sink.** The service hands what survives to a `PointerSink`. `RecordingSink` (tests, and any run that must not inject) records the
events. `CGEventPointerSink` is the only code that moves a real cursor: relative motion clamped to the displays, clicks with their count,
held buttons and drags, pixel scrolling, release-all. It ignores zoom and swipes and does not synthesize momentum, and says so (HELLO_ACK
capabilities 0, so the phone hides those buttons). **No test, script or `make` target constructs it** (a test enforces that for the test
sources); the daemon builds it at start-up and uses it only for a session that passed everything above, which cannot exist unless
`assist on` and `assist pointer on` were run on that Mac.

## Live test (NOT DONE: blocked)

Live pointer injection has **not** been run, anywhere, and is blocked until the captain approves a safe test plan (architecture decision
D7: a scratch Mac or a macOS VM). `scripts/assist-live-pointer-test.sh` is the test, **disabled**: it exits at once unless the captain's
approval is recorded in the same commit that flips `ENABLED`, the machine carries the marker file `~/.greenfield-scratch-mac`, and
`GREENFIELD_ASSIST_LIVE_POINTER=I-AM-ON-THE-SCRATCH-MAC` is set. Enabled, it starts a throwaway daemon on loopback with its own settings
directory, opens a session, and sends a 40-point square of motion with `scripts/assist_tpt1_probe.py` (a second, independent TPT1 encoder,
checked against the kit's recorded datagrams by `make test`). It sends no clicks and no scroll.

What the supervised test must establish, because nothing here can:

* the cursor follows motion, and a held button drags; clicks of each count land where the cursor is;
* scrolling: whether applications honour the pixel scroll events we post, and whether the system flips the direction again for natural
  scrolling (the kit says the deltas are applied as they are);
* the Accessibility / Input Monitoring prompts, if any, that CGEvent posting raises for the signed daemon;
* that `assist off`, a locked screen and thirty seconds of silence really let go of a held button.

## What is not verified live

* Window list and focus against **real** Accessibility windows. `greenfield-inserter assist check-windows` (also `make assist-check`) is the
  check: it opens two throwaway windows of its own, lists them with the real provider, focuses between them, and closes them, touching no
  other app. It must run from Terminal.app on the Mac: a shell outside the console login session (ssh, a detached multiplexer) cannot create or
  read windows, and the check says so and exits 3.
* Everything about the real pointer sink (above).
* Real UDP over the tailnet. The loopback path is tested with real sockets and the real service.
