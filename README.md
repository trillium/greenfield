# Greenfield (working name)

An iPhone dictation app: tap a button (or make a sound), speak, and the text is transcribed on the phone by NVIDIA's Parakeet speech model, then sent over your private network to the Mac you choose. No audio leaves the phone. SwiftUI, iOS 17+, MIT.

**New here? Start with [docs/onboarding.md](docs/onboarding.md): the whole setup on a Mac and an iPhone, in order, in plain words, ending in text appearing in a document on your Mac.**

The name (Greenfield for now), repo and bundle id are not decided. They are working values in one file, `Config/Base.xcconfig` (`APP_NAME`, `DISPLAY_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`), so each is a one-line change.

Non-speech sounds (tongue clicks, pops, kitty-cmere) start and end dictation through a small editable list of rules, using the same microphone tap and replaceable model packs (`docs/sounds.md`).

## What it does
- **Dictate**: the screen shows the flow state (Idle, Dictating, Review), the last sound heard and a text box. Default rules: kitty-cmere twice starts dictation (also again when text is already in the box, which adds to its end); a tongue click ends it and writes the text into the box; another tongue click submits it to the active computer. The microphone button taps to start and taps to stop, on the same state.
- **Sounds**: live list of every sound the detector recognises, the rule editor, and model packs (install, switch, remove).
- **Outbox**: every submitted text is kept until a computer has it, with its target and the plain reason it is waiting, and a Retry button; the same id is reused, so a Mac that already typed it will not type it twice.
- **Computers**: the Macs this phone can send to, found by themselves (Bonjour on the local network, the tailnet, or the QR code a Mac shows) with a reachability dot each. Computers on your tailnet are trusted by tailnet identity, so there is nothing to type and no secret to keep. Text goes to exactly one Mac, the selected one. An **Advanced** row at the bottom is the only place in the app with a field you can type into, and the normal flow never needs it.
- **Help**: Health (checks everything and says how to fix it), Diagnostics (recent events), About and Attribution: credit for the speech model and libraries (CC BY 4.0 and Apache-2.0).

## Layout
- `App/Sources/Audio`: the microphone. One `AVAudioEngine` tap (`AudioCapture`) publishes 16 kHz mono PCM on a `SampleBus` so several consumers can share it. Also an energy `Endpointer`, the `ListenMachine` state machine, `BackgroundGrace` and `CaptureHeartbeat`.
- `App/Sources/Parrot`, `App/Sources/Flow`: the sound detector, model packs and store, the rules and the flow controller.
- `App/Sources/Dictation`: hold to talk (`DictationSession`, `UtteranceBuffer`) and the speech model (`ParakeetTranscriber`, through FluidAudio).
- `App/Sources/Delivery`: Macs, keys, outbox, the HTTP client and delivery.
- `Spike/`: a separate benchmark app comparing Parakeet, WhisperKit and Moonshine on the phone. Results: `docs/spike-dictation.md`.
- `docs/mac-contract.md`: how the phone talks to the Mac input agent (`greenfield-inserter`, a separate project). `tools/stub-receiver` stands in for it in tests.
- `docs/onboarding.md`: the setup a new person follows, Mac and phone, start to finish.
- `docs/sounds.md`, `docs/attribution.md`, `docs/audio-session.md`, `docs/versioning.md`, `docs/signing.md`.

## Build
1. `brew install xcodegen swiftlint shellcheck`
2. `make core` stages the sound detector libraries and the bundled model from a sibling parrot-app checkout (git-ignored; see `docs/sounds.md`). Builds run it for you when it is missing.
3. `make generate` builds the `.xcodeproj` from `project.yml` (never commit it).
4. `make test` runs the unit tests on a simulator. No Apple account needed.
5. `make check` is the full gate: shell, lint, secrets, version tests, stub receiver tests, unit tests.

To run on a device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`. The speech model (about 0.5 GB) downloads on the first launch and is never in git. Credentials: `docs/signing.md`. Versioning: `docs/versioning.md`.

## Try it without a Mac receiver
`make stub-receiver HOST=<tailnet address> KEY=<secret> PORT=47821 LOG=/tmp/received.jsonl` runs a stand-in receiver that logs what arrives. This is a development stand-in, not a Mac: it asks for a secret because it is not on your tailnet, so add it from Computers > Advanced. A real Mac needs none of that (see [docs/onboarding.md](docs/onboarding.md)).

## Network trust
There is no account system, and a new person never types a connection into the app: the phone and the Mac are on the same tailnet (Tailscale), the Mac accepts text from devices of its own tailnet user, and the app finds the Mac by itself over the tailnet, over the local network (Bonjour) or from the QR code the Mac shows. App Transport Security permits plain http to `*.ts.net` (subdomains included) and to local short names; there is no blanket exception. 100.x tailnet addresses are sent over a plain TCP transport that App Transport Security does not govern. If the phone is not on the tailnet, a tailnet name or address fails at once with a clear message instead of a timeout. Do not expose a Mac receiver to the public internet.

## License
MIT, see `LICENSE`. Third-party notices: `THIRD_PARTY_NOTICES.md`.
