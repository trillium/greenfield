# Mac receiver contract (version 1.0)

What the phone sends and what a Mac-side receiver (the "inserter") must answer. The inserter itself, the part that types the text at the cursor, is a separate project. `tools/stub-receiver/receiver.py` implements this contract without inserting anything, so the phone app can be built and tested against it.

Contract versioning follows `docs/versioning.md`: a breaking change bumps the contract MAJOR and the app MAJOR together.

## Transport and trust
- Plain HTTP over a private network (a Tailscale tailnet). The phone allows plain http only to `*.ts.net` names and local-network hosts (see `App/Resources/AppInfo.plist`). Never expose a receiver to the public internet.
- One receiver per Mac, each with its own secret key. The phone keeps a list of Macs (name, address, key); the key is stored in the iOS Keychain, never in preferences or logs.
- The key travels in the `X-Dictation-Key` request header. It is never put in a URL.
- Audio never leaves the phone. Only text is sent.

## `POST /text`
Insert text at the cursor of the Mac's focused field.

Request: `Content-Type: application/json`, body at most 4096 bytes.
```json
{ "id": "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E", "text": "Hello, world." }
```
- `id`: a UUID the phone generates once per utterance and reuses on every resend.
- `text`: UTF-8. The receiver normalises to NFC, strips control characters (including newlines and tabs), and rejects the request if nothing is left. The phone sends one line; there is never an Enter keystroke in v1.

Responses (JSON body, `Content-Type: application/json`):

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"ok":true,"status":"inserted","id":"...","ms":12,"duplicate":false}` | Inserted. `ms` is the Mac-side time. |
| 200 | `{"ok":true,"status":"inserted","id":"...","duplicate":true}` | This `id` was already inserted (the receiver remembers the last 100); nothing was typed again. Safe to resend. |
| 401 | `{"ok":false,"error":"bad_key"}` | Missing or wrong key. |
| 409 | `{"ok":false,"error":"secure_input"}` | A password field or other secure input is focused; nothing inserted. |
| 413 | `{"ok":false,"error":"too_large"}` | Body over 4096 bytes. |
| 422 | `{"ok":false,"error":"invalid_text"}` | Not JSON, no `id`/`text`, or text empty after sanitising. |
| 423 | `{"ok":false,"error":"locked"}` | The Mac's session is locked; nothing inserted. |
| 429 | `{"ok":false,"error":"rate_limited"}` | Too many requests; retry later. |

Only a 200 means the text is on the Mac. Every other outcome keeps the transcript in the phone's outbox, where it can be resent with the same `id`. A request that times out is also kept: it may or may not have arrived, and the `id` makes the resend safe.

## `GET /status`
Used for the reachability dot beside each Mac. Needs the key header like every other route.
```json
{ "ok": true, "contract": "1.0", "name": "MacBook", "locked": false, "secure_input": false,
  "frontmost_bundle_id": "com.apple.TextEdit", "idle_seconds": 3.2 }
```
`contract` is `MAJOR.MINOR`; the phone refuses a receiver whose MAJOR it does not know. A 401 here shows the Mac as reachable with a wrong key.

## Target selection
Exactly one Mac per utterance, the one selected on the phone. The phone never broadcasts and never falls back to another Mac when the selected one fails.
