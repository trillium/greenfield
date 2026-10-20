# Mac input agent: what the phone speaks

The phone sends text to a small agent on each Mac, `greenfield-inserter` (its own project; protocol and setup in its `mac/README.md`), which inserts the text at the cursor of the focused app. This page is the phone's side: which parts of that API the app uses and how it reads the answers. `tools/stub-receiver/receiver.py` speaks the same API without inserting anything, for tests.

## Transport and trust
- Port `47821`. Plain HTTP over the tailnet. The trust boundary is tailnet membership: the agent trusts callers by their tailnet identity, so the app needs no key and the preset computers work out of the box. The app can still send an optional key in the `X-Dictation-Key` header (Computers > edit > Advanced; never in a URL, a log or the repository; kept in the iPhone Keychain, this device only). A 401 is shown as "this computer asks for a key" only when the agent asks for one.
- iOS App Transport Security allows plain http to `*.ts.net` (subdomains included) and to local short names; there is no blanket exception. 100.x tailnet addresses are sent over a plain TCP transport (`HTTPTransport.swift`) because ATS cannot allow an address range. Before sending to a tailnet name or address the app checks that the phone is on the tailnet and says so if it is not.
- Audio never leaves the phone. Only text is sent.

## `GET /status`
Used for the status line and dot beside each computer. The app reads `name`, `version`, `screen_locked`, `secure_input`, `accessibility` and `inserted_count`:

| Answer | Shown as |
|---|---|
| 200, everything fine | green: "Ready (agent <version>)" |
| 200, `accessibility` false | orange: needs Accessibility approval on that computer |
| 200, `screen_locked` | orange: ready, but its screen is locked |
| 200, `secure_input` | orange: ready, but a password field is focused |
| 401 | orange: the agent asks for a key (or refuses the saved one); fix under Advanced |
| 503 `key_not_configured` | orange: an older agent that is not set up yet; update and restart it |
| no answer | red: the reason (not on the tailnet, unreachable, timed out) |

A computer with no key saved is checked like any other; a missing key is never reported as a problem.

## `POST /text`
```json
{ "id": "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E", "text": "Hello, world.", "source": "greenfield" }
```
`id` is generated once per submitted text and reused on every resend; the agent answers a repeat with `200` and `"duplicate": true` and types nothing. The phone sends one line per submit, up to 256 KiB.

| Status / `error` | Meaning in the app |
|---|---|
| 200 | sent (a duplicate counts as sent) |
| 401 `unauthorized` | the agent asks for a key (or refuses the saved one) |
| 503 `key_not_configured` | an older agent that is not set up yet |
| 503 `accessibility_not_granted` | the agent needs Accessibility approval |
| 409 `secure_input` | a password field is focused; nothing typed |
| 423 `screen_locked` | the screen is locked; nothing typed |
| 400 `bad_request`, 413 `too_large`, 500 `insert_failed` | refused, with a message |
| no answer or a timeout | unreachable; the text may or may not have arrived, and the id makes a resend safe |

Only a 200 counts as delivered. Everything else keeps the text in the outbox, where it can be sent again with the same `id`.

## Which computer
Exactly one computer per submit: the active one, chosen in the Computers tab. The phone never broadcasts and never falls back to another computer when the active one fails.
