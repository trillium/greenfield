# Teach your sounds

Sounds > Teach your sounds records the user's own sounds, sends them to the user's own trainer over the tailnet, and installs the model
that comes back. The whole flow is the shared **ParrotKit** package (`../parrot-kit`, found by `scripts/kit-dir.sh`; `PARROT_KIT_DIR`
overrides): the model pack and store, the sound pack, the teach plan, library and state machine, the trainer client and its discovery, the
Teach screens, and the trainer health lines. The protocol, the file formats and the states are specified there
(`docs/teach-protocol.md` in ParrotKit) and tested there; nothing of it is copied into this app. While MAJOR is 0 the app must be built
against a kit with the same MINOR (`ParrotKitInfo.isCompatible`, pinned in `KitCompatibilityTests`).

## What this app adds

| Piece | Where | What it does |
|---|---|---|
| Detector check | `App/Sources/Parrot/AppModelStore.swift` | The validator injected into `ParrotModelStore`: loads a candidate in this app's detector (`SoundDetector`) exactly as listening does and returns its sounds, so a model that installs will run here. Also the model folder (`Application Support/Sounds/Models`, the one earlier builds used, so installed models carry over), the shipped model and its pattern names |
| Microphone | `App/Sources/Teach/AppTeach.swift` (`SessionMicrophone`) | A take subscribes to the app's one `SampleBus`, so the detector and the speech model keep running on the same audio; no second audio engine. Interruptions of the audio session end the take and keep what was recorded |
| Sound rules held still | `FlowController.setRulesPaused`, wired in `AppModel` | While a take runs, sounds are still heard and listed, but no rule fires, so a click being taught does not start, end or submit anything |
| Trainer candidates | `AppModel` | The `TrainerDirectory` asks `GET /health` of the presets in the build (`GREENFIELD_PRESET_TRAINERS`), every computer in the Computers list, and the tailnet peers `PeerDirectory` finds, all on the trainer's port (`PARROT_TRAINER_PORT` in `Config/Base.xcconfig`, through Info.plist). Whatever answers is a trainer; nothing is typed |
| Raw addresses | `SocketTrainerTransport` | `100.x` addresses go over the plain TCP transport the computers use (App Transport Security cannot allow an address range); names go through `URLSession` (`*.ts.net` is allowed). Every request carries `X-Greenfield-App` |
| Install policy | `AppModel` (`.activateKeepingPrevious`) | The model that comes back is installed and switched to at once; the previous model stays installed and the result offers "Go back to ..." |
| Navigation | `SoundsView` ("Teach your sounds"), `TargetsView` ("Trainer" rows under the computers) | The kit's `TeachView` is pushed from Sounds; the trainers found are listed under Computers |
| Health | `AppModel.healthInputs` | `TrainerHealthReport` lines ("Trainer reachable", "Trainer compatible", each with a fix) are placed in the report. A missing trainer is a warning, never a problem: dictation does not need one |
| Privacy text | `App/Resources/AppInfo.plist`, About | Dictation audio never leaves the phone; sounds recorded under Teach go only to the user's own trainer, only when Train is pressed |

Recordings live in `Application Support/Sounds/Teach` (protected until first unlock, excluded from backups) and are never logged.

## Checking it on a phone

`-selftest-teach YES` (a launch argument, see `SelfTestTeach.swift`) runs the whole flow with made-up audio, never anyone's recordings:
it records the baseline and two synthetic sounds through the real recording path, trains on the trainer found by discovery, installs the
model through a store that runs this app's detector check, switches to it, plays a synthetic sound through a detector built from it, and
goes back. The library and the store are in a temporary folder, so the models in use are untouched. Result lines start with `SELFTEST teach:`.
