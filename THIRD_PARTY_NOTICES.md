# Third-party notices

This app's own code is MIT (see `LICENSE`). `AttributionTests` fails when a package the app links has no credit on the Help > Credits and licences screen, and when a package only the benchmark app uses is not named below.

## In the app
| Component | Licence | What it is | Obligation and how it is met |
|---|---|---|---|
| FluidAudio 0.17.7 (FluidInference), https://github.com/FluidInference/FluidAudio | Apache-2.0 | Swift package that runs speech models with Core ML (linked into the app) | Keep its LICENSE (it ships no NOTICE file); shown with its licence text in Help > Credits and licences. Source unmodified. |
| Components inside FluidAudio (fastcluster, text-processing-rs with NeMo Text Processing, rustfst, flate2, VBx, text frontends) | BSD, MIT, Apache-2.0 | Parts of FluidAudio that come from other projects, listed in its `ThirdPartyLicenses` folder | Their notices are reproduced in full in `App/Sources/Licences/FluidAudio-ThirdParty.txt` and shown in Help > Credits and licences. Whether each is linked into the app after dead-stripping has not been checked, so all are credited. |
| ParrotKit (the shared package of this project's apps) | MIT | Swift package: sound learning, health checks, setup and the Assist screens (linked into the app) | Keep its copyright and permission notice; shown with its licence text in Help > Credits and licences. |
| NVIDIA Parakeet TDT 0.6B v2, Core ML conversion by FluidInference | CC BY 4.0 | Speech recognition weights, downloaded on first run (not bundled, not in git) | Credit NVIDIA, link the licence and the source, state the Core ML conversion. See `docs/attribution.md`; shown in Help > Credits and licences, as two credits (the model, and its conversion by FluidInference). |

The app links Apple system frameworks as well.

## Local build inputs, not committed and not yet cleared for public release
The sound detector library and the sound model are staged by `make core` from a sibling checkout and are never committed. Their licence and provenance for any public release are open decisions (see `docs/sounds.md`).

## In the benchmark app only (`Spike/`, not part of the dictation app)
| Component | Licence | Use |
|---|---|---|
| WhisperKit 1.1.1 (argmax-oss-swift) and the Whisper Core ML models it downloads | MIT | Comparison against Parakeet |
| MoonshineVoice 0.1.5 (moonshine-swift) and the Moonshine models it downloads | MIT | Comparison against Parakeet |
| swift-argument-parser 1.8.2 (Apple) | Apache-2.0 | Resolved because argmax-oss-swift depends on it (its command-line tool); not part of the dictation app |

## Build and test tooling (not shipped in the app)
| Tool | License | Use |
|---|---|---|
| XcodeGen | MIT | Generates the Xcode project from `project.yml` |
| SwiftLint | MIT | `make lint` |
| ShellCheck | GPL-3.0 | `make shell`; run as a separate tool, not linked or distributed |
