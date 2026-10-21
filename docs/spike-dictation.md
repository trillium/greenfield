# Dictation benchmark on the phone (spike)

Status: **stopped early on purpose.** The captain chose Parakeet as the only speech model to pursue, so the Whisper and Moonshine comparison was not finished or repeated. What is here is the one complete run, with its limits stated.

## What was run
- Device: iPhone 17 Pro Max (`iPhone18,2`), iOS 26.6.1; built with Xcode 26.2 on macOS 26.3.1, Release configuration, signed install.
- Benchmark app: `Spike/` (target `DictationSpike`, bundle id `<app id>.spike`). Headless, one process per engine and pass.
- Packages (exact): FluidAudio 0.17.7 (`503b4bd1bbf7220882de39fe8ae6716aae4132da`), WhisperKit from argmax-oss-swift 1.1.1 (`1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`), MoonshineVoice from moonshine-swift 0.1.5 (`45a14f9edf1f2a6913d3aff38c1fd4e72d5b7daa`).
- Models: `FluidInference/parakeet-tdt-0.6b-v2-coreml` (`ee09c569`), `-v3-coreml` (`7dd20fe6`), `parakeet-ultra-coreml` (`95eaa59a`), `parakeet-tdt-ctc-110m-coreml` (`9bc92ead`); `argmaxinc/whisperkit-coreml` (`0f63a780`) variants `openai_whisper-large-v3-v20240930_626MB`, `openai_whisper-small_216MB`, `openai_whisper-base.en`; Moonshine English Streaming tiny/small/medium from the library's own download.
- Test audio: the 12 phrases in `Spike/Phrases/phrases.json` spoken by three macOS `say` voices (Samantha, Daniel, Karen) at 16 kHz, plus a 60.8 s passage (Samantha). Synthetic voices on clean audio: error rates are lower than a real voice in a real room would give. Audio is made by `tools/spike/make_phrases.sh` and never committed.

## Commands
```sh
make spike-audio                                   # test audio with macOS say (gitignored)
make spike-build                                   # compile check of the benchmark app
# signed build + install happens in the desktop session (needs the keychain), then:
tools/spike/run_on_device.sh parakeet-v2 parakeet-v3 parakeet-ultra parakeet-tdt-ctc-110m \
    whisper-large-v3-626mb whisper-small-216mb whisper-base-en \
    moonshine-medium-streaming moonshine-small-streaming moonshine-tiny-streaming
python3 tools/spike/summarize.py build/spike-results/results.jsonl
tools/spike/model_sizes.sh                         # on-disk size of each downloaded model
```
Each engine ran twice: "first run" downloads the model, "relaunch" starts again with the model on disk. Latency is the second pass over the 36 clips (the first pass is for accuracy and the first-call cost). Memory is `phys_footprint` and resident size sampled every 25 ms; neither counts Neural Engine memory, so treat them as lower bounds (the system's own headroom number, `os_proc_available_memory`, dropped by only about 60 MB for Parakeet).

## Results
Device model `iPhone18,2`, iOS 26.6.1.

### Speed and memory (warm pass: 36 clips of 0.8 to 5.9 s, run twice; the second pass is timed)

| Engine | p50 ms | p95 ms | RTF p50 | 60.8 s clip ms | 60.8 s RTF | Peak footprint MB | Peak resident MB |
|---|---|---|---|---|---|---|---|
| `parakeet-v2` | 45 | 51 | 0.016 | 231 | 0.0038 | 77 | 189 |
| `parakeet-v3` | 44 | 57 | 0.015 | 273 | 0.0045 | 60 | 188 |
| `parakeet-ultra` | 47 | 62 | 0.016 | 308 | 0.0051 | 60 | 189 |
| `parakeet-tdt-ctc-110m` | 16 | 19 | 0.006 | 85 | 0.0014 | 57 | 157 |
| `whisper-large-v3-626mb` | 870 | 1,010 | 0.280 | 3,998 | 0.0658 | 119 | 226 |
| `whisper-small-216mb` | 301 | 453 | 0.103 | 2,274 | 0.0374 | 116 | 226 |
| `whisper-base-en` | 54 | 91 | 0.019 | 458 | 0.0075 | 70 | 178 |
| `moonshine-medium-streaming` | 669 | 1,354 | 0.251 | 16,810 | 0.2767 | 743 | 1,077 |
| `moonshine-small-streaming` | 469 | 893 | 0.169 | 11,373 | 0.1872 | 518 | 735 |
| `moonshine-tiny-streaming` | 163 | 354 | 0.063 | 4,155 | 0.0684 | 275 | 405 |

### Thermal state at the start of each run

| Engine | Pass | Thermal before | Thermal after | Waited to cool (s) |
|---|---|---|---|---|
| `parakeet-v2` | cold | nominal | nominal | 0 |
| `parakeet-v2` | warm | nominal | nominal | 0 |
| `parakeet-v3` | cold | nominal | nominal | 0 |
| `parakeet-v3` | warm | nominal | nominal | 0 |
| `parakeet-ultra` | cold | nominal | nominal | 0 |
| `parakeet-ultra` | warm | nominal | nominal | 0 |
| `parakeet-tdt-ctc-110m` | cold | nominal | nominal | 0 |
| `parakeet-tdt-ctc-110m` | warm | nominal | nominal | 0 |
| `whisper-large-v3-626mb` | cold | nominal | fair | 0 |
| `whisper-large-v3-626mb` | warm | fair | fair | 0 |
| `whisper-small-216mb` | cold | fair | fair | 0 |
| `whisper-small-216mb` | warm | fair | fair | 0 |
| `whisper-base-en` | cold | fair | fair | 0 |
| `whisper-base-en` | warm | fair | fair | 0 |
| `moonshine-medium-streaming` | cold | fair | serious | 0 |
| `moonshine-medium-streaming` | warm | serious | serious | 0 |
| `moonshine-small-streaming` | cold | serious | serious | 0 |
| `moonshine-small-streaming` | warm | serious | serious | 0 |
| `moonshine-tiny-streaming` | cold | serious | serious | 0 |
| `moonshine-tiny-streaming` | warm | serious | serious | 0 |

### Start-up

| Engine | Download+prep ms (first run) | Load ms (first run) | Download+load ms | Load ms (relaunch) | First utterance ms (relaunch) |
|---|---|---|---|---|---|
| `parakeet-v2` | 38,520 | 132 | 38,652 | 161 | 61 |
| `parakeet-v3` | 37,156 | 111 | 37,267 | 126 | 48 |
| `parakeet-ultra` | 38,861 | 113 | 38,974 | 180 | 59 |
| `parakeet-tdt-ctc-110m` | 18,918 | 11,569 | 30,487 | 86 | 24 |
| `whisper-large-v3-626mb` | 23,495 | 68,154 | 91,648 | 1,075 | 809 |
| `whisper-small-216mb` | 17,286 | 18,169 | 35,455 | 533 | 303 |
| `whisper-base-en` | 15,241 | 8,102 | 23,343 | 341 | 69 |
| `moonshine-medium-streaming` | 11,602 | 120 | 11,722 | 93 | 178 |
| `moonshine-small-streaming` | 6,322 | 198 | 6,521 | 68 | 131 |
| `moonshine-tiny-streaming` | 2,436 | 25 | 2,462 | 34 | 43 |

### Accuracy (36 clips, 3 voices x 12 phrases)

| Engine | WER % | Exact clips | Empty outputs | Capital + final punctuation % | 60.8 s clip WER % |
|---|---|---|---|---|---|
| `parakeet-v2` | 2.9 | 32/36 | 0 | 94 | 0.5 |
| `parakeet-v3` | 2.6 | 33/36 | 0 | 100 | 0.0 |
| `parakeet-ultra` | 2.9 | 32/36 | 0 | 100 | 0.0 |
| `parakeet-tdt-ctc-110m` | 0.3 | 35/36 | 0 | 94 | 1.0 |
| `whisper-large-v3-626mb` | 4.3 | 30/36 | 3 | 83 | 7.8 |
| `whisper-small-216mb` | 4.3 | 30/36 | 3 | 89 | 50.0 |
| `whisper-base-en` | 4.6 | 29/36 | 3 | 89 | 50.0 |
| `moonshine-medium-streaming` | 10.1 | 15/36 | 0 | 83 | 5.3 |
| `moonshine-small-streaming` | 10.1 | 15/36 | 0 | 92 | 14.1 |
| `moonshine-tiny-streaming` | 15.5 | 9/36 | 0 | 67 | 7.3 |


## Reading them, and what they do not show
- **Parakeet is fast on this phone**: a 1 to 6 s utterance takes about 45 ms (v2/v3/Ultra) and the 60.8 s passage 231 to 308 ms, a real-time factor under 0.02. The 110M model is about 3 times faster still. All four Parakeet builds were measured with the phone at `nominal` thermal state throughout.
- **First-run cost**: the model download took about 21 s and the Core ML preparation about 16 s, 38 s in total for v2. On a launch where the files were already on disk but the app binary was new, loading took about 16 s once; later launches loaded in 0.1 to 0.2 s.
- **Output format**: Parakeet returns capitalised, punctuated text with numbers as digits (for example `$23.45`, `9.30`). The error rate normalises that formatting away, but the spoken "twenty three dollars and forty five cents" counts as three missing words, which is most of the Parakeet errors here.
- **WhisperKit returned nothing for clips under one second** (3 of 36 clips, "Hello world."), and its long-passage output dropped or garbled text for the small and base models (50% WER on the 60.8 s passage).
- **The Whisper and Moonshine rows are not comparable to Parakeet's**: the phone reached `fair` during Whisper large and `serious` during the Moonshine runs, so their latencies are inflated by throttling. A rerun with a cool-down before each engine was started (the benchmark app now waits for `nominal`) and stopped on request; its partial logs are not used here.
- **Not measured**: a real voice, the microphone tap running at the same time, the 50-utterance loop, and a 30 minute soak. The dictation app measures the first two itself when the captain uses it.

## Decision
Parakeet TDT 0.6B v2 stays the default (`ParakeetTranscriber.defaultVersion`): English, punctuated output, 45 ms per utterance. v3 and Ultra measured the same speed and are CC BY 4.0 as well, so switching is a one-line change if a multilingual or higher-accuracy build is wanted later.
