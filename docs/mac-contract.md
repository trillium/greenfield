# Mac input agent: what the phone speaks

The phone sends text to a small agent on each Mac, `greenfield-inserter` (its own project; protocol and setup in its `mac/README.md`), which inserts the text at the cursor of the focused app. This page is the phone's side: which parts of that API the app uses and how it reads the answers. `tools/stub-receiver/receiver.py` speaks the same API without inserting anything, for tests.

## Transport and trust
- Port `47821`. Plain HTTP over the tailnet; the trust boundary is tailnet membership plus a per-computer key in the `X-Dictation-Key` header (never in a URL, a log or the repository). Each computer has its own key; the app keeps them in the iPhone Keychain, this device only.
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
| 401 | orange: wrong key |
| 503 `key_not_configured` | orange: no key set on that computer yet |
| no answer | red: the reason (not on the tailnet, unreachable, timed out) |

A computer with no key saved on the phone is shown as "Enter this computer's key" and is not contacted.

## `POST /text`
```json
{ "id": "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E", "text": "Hello, world.", "source": "greenfield" }
```
`id` is generated once per submitted text and reused on every resend; the agent answers a repeat with `200` and `"duplicate": true` and types nothing. The phone sends one line per submit, up to 256 KiB.

| Status / `error` | Meaning in the app |
|---|---|
| 200 | sent (a duplicate counts as sent) |
| 401 `unauthorized` | the key is wrong |
| 503 `key_not_configured` | that computer has no key yet |
| 503 `accessibility_not_granted` | the agent needs Accessibility approval |
| 409 `secure_input` | a password field is focused; nothing typed |
| 423 `screen_locked` | the screen is locked; nothing typed |
| 400 `bad_request`, 413 `too_large`, 500 `insert_failed` | refused, with a message |
| no answer or a timeout | unreachable; the text may or may not have arrived, and the id makes a resend safe |

Only a 200 counts as delivered. Everything else keeps the text in the outbox, where it can be sent again with the same `id`.

## Which computer
Exactly one computer per submit: the active one, chosen in the Computers tab. The phone never broadcasts and never falls back to another computer when the active one fails.
