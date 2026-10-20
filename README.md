# dictation-app (working name)

An iPhone dictation app: hold a button, speak, and the text is transcribed on the phone by NVIDIA's Parakeet speech model, then sent over your private network to the Mac you choose. No audio leaves the phone. SwiftUI, iOS 17+, MIT.

The name, repo and bundle id are not decided. They are working values in one file, `Config/Base.xcconfig` (`APP_NAME`, `DISPLAY_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`), so renaming is a one-line change each.

Sound triggers (pops, hisses and similar non-speech sounds) are planned to join the dictation engine later, in the same audio session, using replaceable model packs. That is not built yet.

## Layout
- `App/Sources/Audio`: microphone building blocks. One `AVAudioEngine` tap (`AudioCapture`) publishes 16 kHz mono PCM on a `SampleBus`, so several consumers can share it. Also an energy `Endpointer`, the `ListenMachine` state machine, `BackgroundGrace` and `CaptureHeartbeat`.
- `docs/spike-dictation.md`: the on-device benchmark of Parakeet, WhisperKit and Moonshine.
- `docs/mac-contract.md`: the HTTP contract between the phone and a Mac-side inserter (the inserter itself is a separate project; `tools/stub-receiver` is a stand-in for tests).
- `docs/attribution.md`: model and library licences shown in the app.

## Build
1. `brew install xcodegen swiftlint shellcheck`
2. `make generate` builds the `.xcodeproj` from `project.yml` (never commit it).
3. `make test` runs the unit tests on a simulator. No Apple account needed.
4. `make check` is the full gate: shell, lint, secrets, version tests, unit tests.

To run on a device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`. Credentials: `docs/signing.md`. Versioning: `docs/versioning.md`.

## Network trust
There is no account system. The app expects to reach the Mac over a private network (for example a Tailscale tailnet), and each Mac has its own key. App Transport Security permits plain http only to `*.ts.net` and local-network hosts. Do not expose a Mac receiver to the public internet.

## License
MIT, see `LICENSE`. Third-party notices: `THIRD_PARTY_NOTICES.md`.
