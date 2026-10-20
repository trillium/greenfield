# Attribution and licences

What the app shows (About > Attribution), and why.

## Speech model: NVIDIA Parakeet (CC BY 4.0)
The app transcribes with NVIDIA's Parakeet TDT 0.6B v2, in the Core ML conversion published by FluidInference (`FluidInference/parakeet-tdt-0.6b-v2-coreml`). The weights are licensed under Creative Commons Attribution 4.0 International. That licence asks for four things, and the attribution screen provides each:

| CC BY 4.0 asks for | Where it is |
|---|---|
| Who created the material | "created by NVIDIA Corporation" (`ModelInfo.modelNotice`) |
| A notice of the licence, with its text or a link | the licence name and a link to `https://creativecommons.org/licenses/by/4.0/` |
| A link to the material | link to `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2` |
| An indication of any change | "converted to Core ML by FluidInference; that conversion is a change to the original" |

The weights are never committed to this repository and never bundled in the app. FluidAudio downloads them into the app's own storage the first time the app runs (about 0.5 GB, with a progress bar), so the app's code license (MIT) stays separate from the model's.

The shown model name is fixed in `App/Sources/Dictation/ModelInfo.swift` and must change together with `ParakeetTranscriber.defaultVersion` if the default model changes; the other Parakeet builds under evaluation (v3, Ultra, TDT-CTC 110M) are CC BY 4.0 as well.

## Libraries
| Component | Licence | Used for |
|---|---|---|
| FluidAudio (FluidInference) | Apache-2.0 | Runs the model with Core ML. Its licence and notices are kept in `THIRD_PARTY_NOTICES.md` and shown in the app. |
| WhisperKit / argmax-oss-swift (Argmax) | MIT | Benchmark app only (`Spike/`), not in the dictation app. |
| MoonshineVoice / moonshine-swift (Moonshine AI) | MIT | Benchmark app only. |

The benchmark app downloads other speech models (Whisper, Moonshine) to compare against Parakeet. They are fetched at run time to the test phone, never committed, and not shipped.

## Not claimed
The app does not claim NVIDIA, FluidInference or any other name above endorses it.
