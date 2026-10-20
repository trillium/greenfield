# Third-party notices

This app's own code is MIT (see `LICENSE`).

## In the app
| Component | Licence | What it is | Obligation and how it is met |
|---|---|---|---|
| FluidAudio 0.17.7 (FluidInference), https://github.com/FluidInference/FluidAudio | Apache-2.0 | Swift package that runs speech models with Core ML (linked into the app) | Keep its LICENSE and NOTICE; shown in About > Attribution. Source unmodified. |
| NVIDIA Parakeet TDT 0.6B v2, Core ML conversion by FluidInference | CC BY 4.0 | Speech recognition weights, downloaded on first run (not bundled, not in git) | Credit NVIDIA, link the licence and the source, state the Core ML conversion. See `docs/attribution.md`; shown in About > Attribution. |

The app links Apple system frameworks as well.

## In the benchmark app only (`Spike/`, not part of the dictation app)
| Component | Licence | Use |
|---|---|---|
| WhisperKit 1.1.1 (argmax-oss-swift) and the Whisper Core ML models it downloads | MIT | Comparison against Parakeet |
| MoonshineVoice 0.1.5 (moonshine-swift) and the Moonshine models it downloads | MIT | Comparison against Parakeet |

## Build and test tooling (not shipped in the app)
| Tool | License | Use |
|---|---|---|
| XcodeGen | MIT | Generates the Xcode project from `project.yml` |
| SwiftLint | MIT | `make lint` |
| ShellCheck | GPL-3.0 | `make shell`; run as a separate tool, not linked or distributed |
