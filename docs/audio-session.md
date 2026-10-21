# One microphone tap, many consumers

The app opens the microphone exactly once. `AudioCapture` owns the one `AVAudioEngine` input tap, converts every buffer to 16 kHz mono float PCM, and publishes it on `AudioCapture.bus` (a `SampleBus`). Anything that needs audio subscribes to the bus; nothing else touches the engine. A second `installTap` on the same bus throws, so the fan-out has to happen after the tap.

```
mic -> AVAudioEngine input tap (AudioCapture) -> convert to 16 kHz mono -> SampleBus
                                                                            |-- UtteranceGate -> UtteranceBuffer -> speech model   (hold to talk)
                                                                            |-- (later) sound-trigger detector                     (same session)
```

## Rules for a consumer
- `subscribe { chunk in ... }` returns a `SampleBus.Subscription`. Keep it for as long as audio should flow; releasing it or calling `cancel()` unsubscribes. It is safe to do either from any thread, including from inside the sink.
- The sink runs on the audio thread. Copy what it needs and return quickly. No model calls, no locks held for long, no I/O. `UtteranceGate` shows the pattern: append under a short lock, hand the finished utterance to a `Task`.
- Chunks arrive in order, every chunk to every subscriber, about every 85 ms (4096 frames at 48 kHz, converted).
- A consumer must not assume how long a chunk is.

## Session
`AudioCapture` configures `.playAndRecord` with the `.measurement` mode (the least system signal processing, which keeps short non-speech sounds intact) and `.mixWithOthers`, so other apps' audio neither interrupts nor is silenced by the microphone. `ListenMachine` turns interruptions, route changes and resumes into state and retry actions; `DictationSession` carries them out. v1 is foreground only: the microphone is started when the screen opens and stopped when the app leaves the foreground. `BackgroundGrace` and `CaptureHeartbeat` are in place for the background-audio work that comes with the sound triggers and are not used yet.

## Attaching the sound-trigger detector later
Subscribe a detector to `bus` in `DictationSession.startListening()` next to the utterance gate. It sees the same audio the speech model sees, with no second tap and no second session. The pops it detects drive the same hold state machine as the on-screen button (`beginHold` / `endHold`).
