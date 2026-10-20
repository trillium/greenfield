# Greenfield (working name)

An iPhone dictation app: hold a button, speak, and the text is transcribed on the phone by NVIDIA's Parakeet speech model, then sent over your private network to the Mac you choose. No audio leaves the phone. SwiftUI, iOS 17+, MIT.

The name (Greenfield for now), repo and bundle id are not decided. They are working values in one file, `Config/Base.xcconfig` (`APP_NAME`, `DISPLAY_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`), so each is a one-line change.

Non-speech sounds (tongue clicks, pops, kitty-cmere) start and end dictation through a small editable list of rules, using the same microphone tap and replaceable model packs (`docs/sounds.md`).

## What it does
- **Dictate**: the screen shows the flow state (Idle, Dictating, Review), the last sound heard and a text box. Default rules: kitty-cmere twice starts dictation; a tongue click ends it and writes the text into the box; another tongue click submits it to the active Mac. The hold-to-talk button is the fallback.
- **Sounds**: live list of every sound the detector recognises, the rule editor, and model packs (install, switch, remove).
- **Outbox**: every transcript is kept until a Mac has it. Resend with a swipe; the same id is reused, so a Mac that already typed it will not type it twice.
- **Macs**: the list of Macs on your tailnet the phone can send to, each with its own key (in the iPhone Keychain) and a reachability dot. Text goes to exactly one Mac, the selected one.
- **About > Attribution**: credit for the speech model and libraries (CC BY 4.0 and Apache-2.0).

## Layout
- `App/Sources/Audio`: the microphone. One `AVAudioEngine` tap (`AudioCapture`) publishes 16 kHz mono PCM on a `SampleBus` so several consumers can share it. Also an energy `Endpointer`, the `ListenMachine` state machine, `BackgroundGrace` and `CaptureHeartbeat`.
- `App/Sources/Parrot`, `App/Sources/Flow`: the sound detector, model packs and store, the rules and the flow controller.
- `App/Sources/Dictation`: hold to talk (`DictationSession`, `UtteranceBuffer`) and the speech model (`ParakeetTranscriber`, through FluidAudio).
- `App/Sources/Delivery`: Macs, keys, outbox, the HTTP client and delivery.
- `Spike/`: a separate benchmark app comparing Parakeet, WhisperKit and Moonshine on the phone. Results: `docs/spike-dictation.md`.
- `docs/mac-contract.md`: how the phone talks to the Mac input agent (`greenfield-inserter`, a separate project). `tools/stub-receiver` stands in for it in tests.
- `docs/sounds.md`, `docs/attribution.md`, `docs/audio-session.md`, `docs/versioning.md`, `docs/signing.md`.

## Build
1. `brew install xcodegen swiftlint shellcheck`
2. `make core` stages the sound detector libraries and the bundled model from a sibling parrot-app checkout (git-ignored; see `docs/sounds.md`). Builds run it for you when it is missing.
3. `make generate` builds the `.xcodeproj` from `project.yml` (never commit it).
4. `make test` runs the unit tests on a simulator. No Apple account needed.
5. `make check` is the full gate: shell, lint, secrets, version tests, stub receiver tests, unit tests.

To run on a device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`. The speech model (about 0.5 GB) downloads on the first launch and is never in git. Credentials: `docs/signing.md`. Versioning: `docs/versioning.md`.

## Try it without a Mac receiver
`make stub-receiver HOST=<tailnet address> KEY=<secret> PORT=47821 LOG=/tmp/received.jsonl` runs a stand-in receiver that logs what arrives. Add that address and key under Macs in the app.

## Network trust
There is no account system. The app expects to reach the Mac over a private network (for example a Tailscale tailnet), and each Mac has its own key. App Transport Security permits plain http to `*.ts.net` (subdomains included) and to local short names; there is no blanket exception. 100.x tailnet addresses are sent over a plain TCP transport that App Transport Security does not govern. If the phone is not on the tailnet, a tailnet name or address fails at once with a clear message instead of a timeout. Do not expose a Mac receiver to the public internet.

## License
MIT, see `LICENSE`. Third-party notices: `THIRD_PARTY_NOTICES.md`.
