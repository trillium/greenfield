# Third-party notices

This app's own code is MIT (see `LICENSE`).

## Bundled today
Nothing. The app links only Apple system frameworks. It ships no third-party code, model weights, or audio.

## Build and test tooling (not shipped in the app)
| Tool | License | Use |
|---|---|---|
| XcodeGen | MIT | Generates the Xcode project from `project.yml` |
| SwiftLint | MIT | `make lint` |
| ShellCheck | GPL-3.0 | `make shell`; run as a separate tool, not linked or distributed |

## Planned (not yet included)
On-device speech recognition on top of `App/Sources/Audio` is expected to add these dependencies. Their notices must be added here before they ship:

| Component | License | Obligation |
|---|---|---|
| NVIDIA Parakeet TDT model weights | CC-BY-4.0 | Attribution to NVIDIA, link to the license, state changes (e.g. CoreML conversion). Weights are downloaded at runtime or bundled, never committed. |
| FluidAudio (Swift package) | Apache-2.0 | Keep its LICENSE and NOTICE; mark modified files. |
