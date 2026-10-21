# Greenfield as a web app (PWA), for testers who do not want to install an app

`pwa/` is an **experimental** web version of Greenfield: a page a tester opens in a browser and adds to the home screen, with no app to install. It has the same three screens as the phone app, **Dictate**, **Computers** and **Help**, and sends text to a computer's helper (`greenfield-inserter`, the Mac or the Windows one) with the same contract as the phone (`docs/mac-contract.md`).

> **Status: experimental, and not yet tried on a real iPhone.** Everything here is proven by unit tests with fakes and by a smoke test in desktop Chrome against the real Windows helper (`make test-pwa`, `make test-pwa-smoke`). Safari on iOS, the home-screen install and the microphone on a real phone are the first thing the checklist at the end asks someone to try. Nothing has been exposed beyond this computer: the tailnet recipe below is written down, not run.

## What works

- **Dictate** (concepts V1 and V2 in the kit's `docs/concepts.md`): the browser's own speech recognition fills the text box where it exists (Safari on iPhone, iPad and Mac as `webkitSpeechRecognition`; Chrome and Edge as `SpeechRecognition`). Where it does not, the screen says why in plain words and the box still takes typing. Tap **Dictate** to start and again to stop; a **New line** button adds a line break (the recognizer has no spoken "new line").
- **Line breaks are the Enter key**, exactly as in the phone app: each line break in the box is sent as a line feed, which the helper types as a Return key press; empty lines and a trailing newline are kept; only spaces and tabs at the two ends are dropped. The box shows a grey **↵** marker at every line break. The marker is drawn behind the text (display only), so it can never end up in what is sent.
- **Submit** sends the whole box to the **one** chosen computer. The text is queued first with a fixed id, so a resend is safe (the helper answers `duplicate` instead of typing twice). Only a `200` counts as sent; anything else keeps the text under **Computers > Waiting to send**, with the plain reason and a Retry (also **Retry all**, and automatically when the browser comes back online). It never falls back to another computer.
- **Computers** (C1 to C3, C5, C7): the computers this page can reach, each with a status line that has a word as well as a colour (Ready, Needs approval on that computer, Its screen is locked, Pairing ended, Cannot be reached), one-time **pairing**, **Use**, **Pair again** and **Forget**.
- **Help**: Health (every computer at once), how it works, what it cannot do, privacy, **Forget all pairings**, the version.
- **Installable and offline-opening**: a web manifest, icons made from the app icon, and a service worker that keeps the app's own files (and nothing else) so it opens with no connection. Sending still needs the network.
- The page loads no script, style, font or image from anywhere else, and its server sets a strict Content-Security-Policy.

## What cannot work (and why)

| Not possible | Why |
|---|---|
| Dictation in the background, or with the screen locked | A web page can only listen while it is open and in front. There is no background listening (the phone app's P1). The page asks the browser to keep the screen awake while it listens, which helps, but a locked phone stops it. |
| The microphone on a page that is not **https** (or `localhost`) | Browsers refuse the microphone to an insecure page. A phone must therefore open the page through the `tailscale serve` https address below, never `http://100.x.x.x:...`. |
| A share sheet ("send this to Greenfield") | Web apps on iOS cannot register as a share target. |
| Sounds, assist (window switcher, trackpad), model packs, Teach | Out of scope: they need the phone app's own audio engine and local network access. |
| Audio that never leaves the device | **The phone app keeps dictation audio on the phone. The web app cannot promise that:** the browser's recognizer may send the audio to Apple (Safari) or Google (Chrome) to turn it into text. The page says so under Help > Privacy. Only the text is ever sent to your computer; audio never is. |
| Finding computers by itself | A browser cannot scan a tailnet or the local network. The page's own server lists the computers it forwards to (below); a tester pairs with each. |
| Spoken line enders ("send it"), voice commands | Not ported (V3 and V5 stay phone-only). |

## How it fits together

```
tester's browser  --https-->  tailscale serve  -->  pwa/server.mjs  -->  helper of each computer
   (the page)               (tailnet only)        127.0.0.1:47830       http://computer:47821
```

- `pwa/server.mjs` has no dependencies and no build step. It serves the app's files, `GET /computers.json` (the helpers it forwards to), and `/helper/<id>/<route>` for exactly four routes of a helper: `GET /status`, `POST /text`, `POST /pair`, `POST /pair/revoke`. Asking for a pairing code, listing devices, logs, peers and the assist tools are **not** forwarded.
- Putting the page and the helper behind **one origin** is what makes this work from a phone: an https page may not call a plain-http helper (mixed content), and the helpers send no CORS headers.
- It listens on **loopback only**. Nothing but `tailscale serve` (or the person at that computer) can reach it.
- It marks every request it forwards with `X-Forwarded-For`. **A helper never treats a request with a proxy header as coming from the person at that computer**, even when it arrives from loopback; it lets it in only with a paired device's token (next section). This matters because `tailscale serve` and this server both reach a helper from `127.0.0.1`; without that rule they would have been trusted as "this computer".

## Pairing: a one-time code for a scoped token

A tester outside the tailnet identity of the computer (a different user, or a browser with no tailnet identity of its own) cannot be recognised the way the phone is. Instead:

1. On the computer, run `greenfield-inserter pair`. It shows a code like `ABCD-EFGH`. (Only the person at the computer can ask for one: the route answers loopback only, and never a request that carries a proxy header.)
2. In the web app, Computers > the computer > **Pair**, type the code.
3. The helper answers with a **token**. The page keeps it on that device and sends it only to that computer, in the `X-Greenfield-Token` header (never in a URL).

| | |
|---|---|
| Code | 8 letters and digits with no look-alikes (`0 O 1 I L`), shown as `ABCD-EFGH`; 5 minutes; **single use**; one is live at a time (a new code replaces the old one); 5 wrong guesses burn it; at most 10 attempts a minute over everyone. |
| Token | 256 bits of secure randomness; **24 hours**; one per device; at most 16 live devices; the helper keeps only its SHA-256, in memory. |
| Reach | `GET /status` and `POST /text` only. Not the computer list (`/peers`), not the logs, not the assist tools, not pairing. The same limits as the optional key on the Mac. |
| Revoke | `greenfield-inserter pair --list`, `pair --revoke ID`, `pair --revoke-all`; the page's **Forget** and **Forget all pairings** end its own token at the helper; restarting the helper forgets every code and token. |
| Never logged | The helper logs `pair code issued`, `paired device id=...`, `pair refused`, `pair revoked ...`: never a code or a token (tests check this), and its log redactor masks a token header and long opaque strings as well. The page's server never reads, logs or stores a token. |
| Trust path | Unchanged. The tailnet-identity check, the Mac's optional key and the Windows helper's "no keys" rule behave exactly as before for every request without a token. A wrong, expired or revoked token is refused with `401 invalid_token`; it is never retried as something else. |

Pairing is on **both** helpers with the same routes, limits and answers (`mac/Sources/InserterCore/Pairing.swift`, `windows/internal/pairing`):

| Route | Who | Answer |
|---|---|---|
| `POST /pair/code` | this computer only (loopback, no proxy header) | `{ok, code, expires_in_s, name}` |
| `POST /pair` `{code, device}` | anyone who can reach the port (the code is the credential) | `200 {ok, token, device, expires_in_s, name, version}`, `401 pair_refused`, `429 rate_limited`, `400 bad_request` |
| `GET /pair/devices` | this computer only | `{ok, devices: [{id, name, created_at, expires_at, last_seen}]}` (never a token) |
| `POST /pair/revoke` | this computer: `{id}` or `{all: true}`; a paired device: its own token, no body | `{ok, revoked}`, `404 no_such_device`, `401` |

The routes are additive; per `docs/mac-contract.md` that is a MINOR change on the helpers' next release (both helpers move together). A tester can be locked out of pairing by someone hammering `POST /pair` (the 10-a-minute limit is shared); that costs a minute, not security.

## The test surface

```
make pwa-serve          # http://localhost:47830 on this computer only (GREENFIELD_PWA_PORT in .env)
make test-pwa           # unit tests with fakes: node --test pwa/test/ (Node 20 or newer)
make test-pwa-smoke     # the page in a real Chrome (chrome-devtools-axi), through the server, against the real Windows helper in dry-run
```

- The port is `GREENFIELD_PWA_PORT` (default in `.env.example`; a `--port` flag or an exported variable wins). The helper it talks to is this computer's own, on `GREENFIELD_PORT`. For more computers set `GREENFIELD_PWA_HELPERS="Studio Mac=http://studio.tail1234.ts.net:47821, Office PC=http://pc.tail1234.ts.net:47821"` before `make pwa-serve`; the server reaches them over the tailnet with its own identity, and the tester still pairs with each.
- `make test-pwa` runs in `make check`. The smoke test is separate because it needs Chrome and Go; it picks free ports, keeps its state in a temporary directory and leaves nothing running. It covers: the three screens, the Enter marker, the computer list, refusing a send before pairing, a wrong code, a real code, a send (checked in the helper's own log), no code or token in that log, and Forget ending the pairing at the helper.
- On the Mac the real daemon can be the helper: `greenfield-inserter pair` works the same there. `windows/`'s `make run` (a dry run that types nothing) is the safest helper to try the page against.

### Tailnet-only HTTPS for a phone (a recipe, **not run**)

Do not run this until the captain has decided. It needs HTTPS certificates and MagicDNS turned on for the tailnet (Tailscale admin console > DNS), and it publishes the page to **every device on the tailnet**, nobody else.

```
make pwa-serve                        # in one terminal: the page on 127.0.0.1:47830
tailscale serve --bg 47830            # in another: https://<this-computer>.<tailnet>.ts.net/  (tailnet only)
tailscale serve status                # shows what is served, and that Funnel is off
tailscale serve reset                 # takes it down again
```

- **Never** `tailscale funnel`: that is the public internet. If `tailscale serve status` ever says "Funnel on", run `tailscale funnel reset` and tell the captain.
- Everyone on the tailnet can then open the page and ask to pair, but nothing is sent anywhere without a code that only the person at the computer can create.
- The helper itself stays on its own port, on the tailnet and loopback, as today; the page reaches it through the server.

## Tester steps

1. On the computer that will type: make sure its helper is running (`greenfield-inserter health` says Ready; on Windows see `docs/windows.md`), and the person running the test knows the page's address (given to them).
2. On the phone: open the address in **Safari**, tap Share > **Add to Home Screen**, open **Greenfield** from the home screen. (It also works in a browser tab.)
3. **Computers**: tap **Pair** next to the computer. On the computer run `greenfield-inserter pair` and type the code it shows. The line turns to "✓ Ready".
4. **Dictate**: click where the text should go on the computer, tap **Dictate**, allow the microphone, speak, tap **Stop**. Use **New line ↵** for an Enter. Tap **Submit to ...**.
5. The words appear at the cursor on the computer. If they do not, **Computers > Waiting to send** says why and has **Send again**.
6. When done: **Help > Forget all pairings**, or on the computer `greenfield-inserter pair --revoke-all`.

## Checklist (try on real devices)

- [ ] `make test-pwa` and `make test-pwa-smoke` pass on a Mac.
- [ ] `make pwa-serve` opens at `http://localhost:47830` and dictation works in desktop Chrome or Safari (microphone allowed).
- [ ] The Mac daemon: `greenfield-inserter pair` shows a code; the page pairs; text arrives in TextEdit with line breaks as Return; `pair --list` shows the browser; `pair --revoke ID` makes the next send say "pair again".
- [ ] The Windows helper: the same, in Notepad.
- [ ] A wrong code is refused; a used code is refused; a code left 5 minutes is refused.
- [ ] After **Forget**, `pair --list` is empty.
- [ ] (After the captain approves) `tailscale serve --bg 47830` on the Mac; `tailscale serve status` shows no Funnel; the https address opens on an iPhone on the tailnet.
- [ ] iPhone, Safari: the microphone prompt appears; dictation fills the box; the ↵ marker shows; Add to Home Screen gives a Greenfield icon that opens full screen.
- [ ] iPhone: the screen locking or switching app stops dictation, and the page says it stopped rather than silently losing words.
- [ ] A text sent with the helper stopped lands in Waiting to send and goes out with Send again once it runs (and arrives once, not twice).
- [ ] No pairing code or token appears in `greenfield-inserter logs` on either helper.

## Follow-up for the parity matrix (not edited here)

The matrix is generated by the kit's `scripts/parity-matrix.sh` from `docs/concepts.md`, `scripts/parity/apps.tsv` and `scripts/parity/rules.txt`. To list the web app as a column, add one line to `apps.tsv` (`pwa	Web app	dictation-app	default`) and rules in `rules.txt`; a test file that carries `concept: ID` is picked up without a rule, and the tests in `pwa/test/` already carry them. Suggested cells:

| Concept | Web app | Where |
|---|---|---|
| V1 Dictate | partial: the browser's recognizer (audio may leave the device) | `pwa/src/speech.js`, `pwa/src/text.js` |
| V2 Submit | done | `pwa/src/send.js` |
| V3 Line-ender | n/a: no spoken line enders; a New line button | |
| V4 Utterance handling | n/a: the browser's recognizer decides | |
| V5 Voice command, V6 Speech model | n/a | |
| S1 to S8 Sounds, A1 to A3 Assist | n/a: out of scope for the web app | |
| F1, F2 Flow, guided first run | n/a | |
| C1 Computers | done | `pwa/src/app.js`, `pwa/src/computers.js` |
| C2 Discovery | partial: the page's server lists the computers | `pwa/src/computers.js` |
| C3 Authentication | done: one-time pairing | `pwa/src/pairing.js` |
| C4 Compatibility | missing: no version header yet | |
| C5 Outbox and retry | done | `pwa/src/send.js` |
| C6 Delivery evidence | partial: the helper's `delivery` is kept, not shown | |
| C7 Link health | done | `pwa/src/send.js` (`interpretStatus`) |
| H1 Health | partial: every computer's status | |
| P1 Background listening | n/a: a page cannot | |
| SH Shell and Help home | done | `pwa/index.html` |

## Files

`pwa/index.html`, `app.css`, `manifest.webmanifest`, `sw.js`, `icons/`; `pwa/src/` (`text.js`, `store.js`, `pairing.js`, `send.js`, `speech.js`, `computers.js`, `app.js`); `pwa/server.mjs`; `pwa/test/` (unit tests, a fake helper, `smoke.sh`).
