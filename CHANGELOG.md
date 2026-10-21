# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: docs/versioning.md.

## [Unreleased]

### Added
- A Windows input daemon, `windows/` (`greenfield-inserter.exe`, Go, one static file for windows/amd64 and windows/arm64, `make windows`): the same routes, port, JSON and error codes as the Mac daemon, so the phone needs no change. Text is typed with `SendInput` (Unicode key events, every line break a real Return key press); trust is the tailnet identity from the local Tailscale (no key, no password); computers are found by `GET /peers`, local-network discovery and the add link; `health`, `doctor`, `ready` and `selftest` equivalents; the Assist tools answer "not supported". **Not yet run on a real Windows computer**: `docs/windows.md` has the parity matrix, the known limits and a checklist for trying it.
- An experimental web version, `pwa/` (Dictate, Computers, Help; `make pwa-serve`, `docs/pwa.md`), for testers who do not want to install the app: the browser's speech recognition, line breaks sent as Enter with the return marker shown, a queue with retry, and one-time pairing of a browser with a computer. Both helpers gain the pairing routes (`greenfield-inserter pair`): a short-lived, per-device, revocable token that reaches `/status` and `/text` only. A request that carries a proxy header is no longer taken for the person at that computer. A tailnet-only HTTPS recipe with `tailscale serve` is documented, not run. Not yet tried on a real iPhone.

## [0.4.0] - 2026-10-21

The app and the Mac daemon move to the 0.4 line together (while MAJOR is 0 the MINOR must match; `docs/mac-contract.md`). The daemon's entry is in `mac/CHANGELOG.md`.

### Added
- The Mac daemon is the helper for the phone's assist tools, off until `greenfield-inserter assist on`: a window switcher (`GET /assist/windows`, `POST /assist/windows/focus`) and a trackpad receiver (`POST /assist/pointer/session` and an authenticated UDP stream). `GET /status` gains `assist`. See `mac/docs/assist-pointer.md`.
- A disabled live pointer test and an independent encoder for the pointer wire; live pointer injection is not approved yet.
- The app uses the shared kit's WordToggle for the phrase and rule switches, asks to confirm before every destructive action, honours Reduce Motion and Differentiate Without Colour, and adds headings, hints, named actions and large-text layouts.
- unify version.sh for the sibling repos

### Fixed
- Every control has a visible name, decorative icons are hidden from VoiceOver, and status colours come from the shared tokens with every status named in words.

## [0.3.0] - 2026-10-21

The app and the Mac daemon move to the 0.3 line together (while MAJOR is 0 the MINOR must match; `docs/mac-contract.md`). The daemon's own entries for 0.2.1 to 0.3.0 are in `mac/CHANGELOG.md`.

### Added
- Onboarding: a checklist with one-tap fixes, a guided first dictation, a QR scan for the Mac link and a single "Am I ready?" line; every red state names a fix and nothing asks a person to type a key or address (those fields live under Advanced).
- Teach your sounds, on the shared ParrotKit package.
- Spoken line-enders ("send it", "over and out"), an always-visible Submit and Retry all; queued texts retry by themselves with backoff.
- Logs without a cable: a redacted support log with a Share logs button in the app, `GET /logs` on the daemon, and `make logs TARGET=phone|macbook|mini0|trainer|all` (`docs/logs.md`). URL queries, launch-argument secrets and known values are masked.
- One-command Mac onboarding (`mac/install.sh`, a live setup checklist, `ready`), the port read from `.env`, and `scripts/onboarding-check.sh` to score onboarding by facts.
- Commit tooling: Conventional Commits are validated by a hook and by `make check-commits`, and `make release-check` suggests the semver bump.

### Fixed
- An untagged build no longer raises a false "Update the Mac daemon" against the declared peer floor.
- The Mac `--help` handler works when invoked from the repository root.

## [0.2.0] - 2026-10-20

### Breaking
- Tailnet identity replaces the per-computer key, and the Mac agent's API gains delivery evidence and a version contract. App 0.2.x works only with agent 0.2.x (while MAJOR is 0 the MINOR must match; `docs/mac-contract.md`). An agent from 0.1.x is reported as "update the Mac daemon".

### Added
- Sound rules: kitty-cmere twice starts dictation (also from review, appending to the text box), a tongue click ends dictation and writes the text, another tongue click submits it. Rules are editable; the sound detector listens on the same microphone tap in every state; sound model packs are swappable.
- Tap-to-start, tap-to-stop microphone button on the same state as the sounds; hold-to-talk is gone.
- Computers: presets from local configuration, one active, per-computer status, discovery (peers from a seed, Bonjour, `greenfield://add` link); no key by default, optional under Advanced.
- Outbox with target, plain reason and Retry; send evidence from the agent (confirmed or not).
- Help: Health (checks everything and says how to fix it, including compatible / update the Mac daemon / update the app) and Diagnostics (recent events).
- Semver compatibility contract: `X-Greenfield-App` on every request, `GREENFIELD_MIN_PEER_VERSION`, contract tests with recorded samples.
- Benchmark app and results for on-device dictation models (Parakeet, WhisperKit, Moonshine).

### Changed
- The speech model screen says whether the model is downloading or only loading.

## [0.1.0] - 2026-10-20

### Added
- Project scaffold: XcodeGen project, build/test/archive scripts, version derived from git tags, release script, secrets check, git hooks, CI shape.
- Audio building blocks: single-tap `AudioCapture` with a `SampleBus` fan-out, `Endpointer`, `ListenMachine`, `BackgroundGrace`, `CaptureHeartbeat`.
- App icon generated by `tools/icon/make_icon.py`.
