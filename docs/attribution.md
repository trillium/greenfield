# Attribution and licences

What the app shows (Help > Credits and licences), and why. The screen is the kit's shared `AboutInfoView` (ParrotKit `docs/about.md`); this
app supplies the credits (`App/Sources/Dictation/AppCredits.swift`) and the licence texts (`App/Sources/Licences/`, bundled so they read offline).

## What the screen shows
- The app's version and build, and the shared package's version.
- *What runs on this phone*, in plain words: the speech model runs on the phone (downloaded once, the first time), the sounds are matched on the phone, the Teach recordings go only to the person's own trainer and only when Train is pressed, text goes only to the computers the person chose, and the Assist tab sends pointer movements and window requests to the computer the person chose. If a change makes one of these untrue, change the line in `AppCredits.strings` in the same commit.
- A credit for each item below, each with the notice as written, links to the source and the licence, and the full licence text.
- Under the credits: the app's own code is MIT, and the names credited do not endorse the app.

## Speech model: NVIDIA Parakeet (CC BY 4.0)
The app transcribes with NVIDIA's Parakeet TDT 0.6B v2, in the Core ML conversion published by FluidInference (`FluidInference/parakeet-tdt-0.6b-v2-coreml`). The weights are licensed under Creative Commons Attribution 4.0 International. That licence asks for four things, and the credits provide each:

| CC BY 4.0 asks for | Where it is |
|---|---|
| Who created the material | "created by NVIDIA Corporation" (`ModelInfo.modelNotice`, the credit's author) |
| A notice of the licence, with its text or a link | the licence named in full in the notice, a link to `https://creativecommons.org/licenses/by/4.0/`, and the full text in the app (`CC-BY-4.0.txt`) |
| A link to the material | link to `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2` |
| An indication of any change | "converted to Core ML by FluidInference; that conversion is a change to the original" (the model's notice), and a second credit for the conversion with a link to FluidInference's page (`ModelInfo.conversionNotice`) |

The weights are never committed to this repository and never bundled in the app. FluidAudio downloads them into the app's own storage the first time the app runs (about 0.5 GB, with a progress bar), so the app's code license (MIT) stays separate from the model's.

The shown model name is fixed in `App/Sources/Dictation/ModelInfo.swift` and must change together with `ParakeetTranscriber.defaultVersion` if the default model changes; the other Parakeet builds under evaluation (v3, Ultra, TDT-CTC 110M) are CC BY 4.0 as well.

## Libraries
| Component | Licence | Used for |
|---|---|---|
| FluidAudio (FluidInference) | Apache-2.0 | Runs the model with Core ML. Credited with its licence text (`Apache-2.0-FluidAudio.txt`, the file from its 0.17.7 release; it ships no NOTICE file). Used unmodified. |
| Components inside FluidAudio | BSD, MIT, Apache-2.0 | FluidAudio's own `ThirdPartyLicenses` (fastcluster, text-processing-rs with NVIDIA NeMo Text Processing, rustfst, flate2, VBx, text frontends), reproduced as FluidAudio publishes them (`FluidAudio-ThirdParty.txt`) and credited as one entry. Whether each part survives dead-stripping into the app was not checked, so all are credited. |
| ParrotKit | MIT | The shared package: sound learning, health checks, setup and the Assist screens. Credited with its licence text (`MIT-ParrotKit.txt`). |
| WhisperKit / argmax-oss-swift (Argmax) | MIT | Benchmark app only (`Spike/`), not in the dictation app, so not on the screen; named in `THIRD_PARTY_NOTICES.md`. |
| MoonshineVoice / moonshine-swift (Moonshine AI) | MIT | Benchmark app only; named in `THIRD_PARTY_NOTICES.md`. |

`swift-argument-parser` (Apache-2.0) is also resolved, because `argmax-oss-swift` depends on it; it is not in the dictation app and is named in `THIRD_PARTY_NOTICES.md`.

The benchmark app downloads other speech models (Whisper, Moonshine) to compare against Parakeet. They are fetched at run time to the test phone, never committed, and not shipped.

## Adding a dependency
Add the package to `project.yml` and its credit to `AppCredits.credits` (with the identity in `packageIDs`, the licence text under `App/Sources/Licences/`). `AttributionTests` fails otherwise: every package the `DictationApp` target links must be credited; every package only `DictationSpike` links must be named in `THIRD_PARTY_NOTICES.md`; and, when Xcode has resolved the packages, every pin in `Package.resolved` is one or the other.

## Not claimed
The app does not claim NVIDIA, FluidInference or any other name above endorses it.
