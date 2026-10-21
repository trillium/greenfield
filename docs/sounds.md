# Sound triggers and the rules that use them

Greenfield listens, on the same microphone tap as dictation (`docs/audio-session.md`), for non-speech sounds: tongue clicks, pops, kitty-cmere clicks and the other sounds in the model. Which sound does what is a short editable list of rules.

## Flow states
| State | Meaning |
|---|---|
| Idle | Nothing happening. |
| Dictating | The microphone is being recorded for the speech model. |
| Review | Dictation ended; the text is in the text box, waiting to be submitted. |

The hold-to-talk button is the fallback and uses the same states: pressing it is "start dictation", releasing it is "end dictation".

## Rules
A rule is: **trigger** (a sound, optionally a count and a time window) + **from state** → **to state** + **action**. When the sound is heard (that many times within the window) while the flow is in the rule's from-state, the rule fires. Rules are checked top to bottom; edit them in Sounds > Edit rules. They are saved on the phone.

Actions: start dictation, end dictation (write the text into the box), submit the text, clear the text, nothing.

Defaults:
| Trigger | From → to | Action |
|---|---|---|
| kitty-cmere twice within 1.5 s | Idle → Dictating | Start dictation |
| tongue-click | Dictating → Review | End dictation and write the text into the text box |
| tongue-click | Review → Idle | Submit the text to the active computer |

After a rule fires, the same sound is ignored for 0.5 s so one click that is reported twice cannot fire two rules. The sound that ends dictation is cut off the audio (0.3 s) so it is not transcribed; the sound that starts dictation is not included either. Submit sends the text box to the active Mac through the outbox; if no Mac is chosen or it cannot be reached, the text stays queued in the outbox and can be sent again. If speech is still being transcribed when a submit arrives, the submit waits for it.

Do not give two rules the same sound and state. Mixing counts for one sound in one state (once and twice) would fire the once-rule first.

## The detector and its model
The detector is a separate library that runs the sound model (`pq_*` C interface, `App/Sources/Parrot/SoundDetector.swift`). `make core` stages the library, its header and the bundled model into `.parrot-core/` (git-ignored) from a sibling checkout (`PARROT_APP_DIR`, default `~/code/parrot-app`); nothing from it is committed here, and the model is personal training data that is never committed.

The model is swappable at run time. `ParrotModelStore` keeps installed **model packs** (one file with the model, its sound names and its patterns, checksummed; format in `ParrotModelPack.swift`) and the chosen one; the bundled model is the fallback. Sounds > Import a model pack installs and activates a pack, after loading it in the detector to prove it runs; a pack that fails to load never becomes active. The patterns (which class names make which pattern name, with thresholds) come from the pack, or from the library's built-in set for the bundled model. The rule editor offers the active model's pattern names.

## Levels
Sounds > Levels is the shared Levels screen (ParrotKit `docs/levels.md`) over this app's detector. It sets **how loud each sound has to be to fire** (one trigger level per sound, with a switch to turn a sound off) and **how sensitive the microphone is** (one input gain), shows a live meter with those levels marked on it, and has **Test <sound>**: make the sound and it says whether it would fire at that level, and if not why (too quiet for the detector's gate, quieter than the level, or not taken for that sound). Every number has a visible plus and minus button; the slider is a shortcut.

How it reaches the rules: the detector is built from the levels (`AppLevels.setup(for:)`). Its pattern set is the active model's patterns (the pack's own, or `patterns.json` for the bundled model, staged by `make core`) with each `>power` replaced by the sound's level and every switched-off sound left out; the gain multiplies the samples the detector hears (`SoundListener`) and nothing else, so speech recognition is untouched. A switched-off sound never reaches the rule engine, so a rule that uses it does not fire. A change is saved at once and the detector is rebuilt when it is final (a button press, a slider released). At the defaults the detector hears exactly what it heard before this screen existed (`AppLevelsTests` replays a recorded clip through both).

Two limits worth knowing. The detector ignores anything under a power of 10, so a level below 10 would do nothing and the screen does not offer it; to reach a quieter sound raise the gain. And the screen reads the sounds of the model in use: when a taught model replaces it, the levels are reconciled with the new model's sounds (names it lost are dropped, names it gained start at their own level).

The settings are one small file, `Application Support/Sounds/levels.json`, in the app's own sandbox (written atomically, readable once the phone has been unlocked after a restart so a locked phone can still listen). They are not in the shared defaults, not in the support log and not sent anywhere.

## Teaching your own sounds
Sounds > Teach your sounds records the user's own sounds on the same microphone tap (the sound rules are held still while a take runs), builds a sound pack, sends it to the user's own trainer over the tailnet, and installs the model that comes back through `ParrotModelStore`: it is switched to at once and the previous model stays installed, with "Go back" on the result. The trainer is found by itself (build preset, the Computers list, tailnet peers); there is nothing to type. The path, the file formats, the endpoints and the states are in [teach-protocol.md](teach-protocol.md) (the flow is the ParrotKit package; this repo's page lists what the app adds). A taught model brings its own pattern names, so rules written for another model's names do not fire until they are edited.

## Open items
- Public release: the detector library's pattern engine and the model's provenance are on hold as open decisions (task-pgozj, task-29wjo). Until they are settled, the detector is a local build input, not something this repository ships.
- Background and locked-screen listening is not done (foreground only), so sounds only work while the app is open.
