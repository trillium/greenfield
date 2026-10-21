# Versioning

Semantic versioning, driven by git tags. Nobody edits a version number by hand.

## The rule

| Bump | When |
|---|---|
| **MAJOR** | A breaking change to the Mac contract ([mac-contract.md](mac-contract.md)) from 1.0.0 on: an old agent can no longer serve the new app, or the reverse. While MAJOR is 0, such a breaking change bumps MINOR instead. |
| **MINOR** | A new user-visible feature. |
| **PATCH** | A fix, or any change users can't see. |

The contract carries its own version (top of `mac-contract.md`). A breaking contract change bumps the contract's MAJOR and the app's MAJOR together; additive contract changes bump the contract MINOR.

## Where the number comes from

The source of truth is the git tag `vX.Y.Z`. `scripts/version.sh` takes the newest one reachable from HEAD (tags with a suffix such as `-rc1` are ignored; no tag at all counts as `0.0.1`):

- On a tagged commit: `MARKETING_VERSION` = that tag's `X.Y.Z`.
- N commits past a tag: the next patch (a dev build of the coming release). The `+N.g<sha>` suffix shows only in `version.sh --full`; the Apple version stays numeric `x.y.z`.
- `CURRENT_PROJECT_VERSION` (build number) = commit count, so it only goes up.

`make generate` (which every build, test and archive runs) writes `Config/Version.xcconfig` (gitignored; also carries `GIT_COMMIT`, the short sha with `-dirty` on uncommitted changes), which `Config/Base.xcconfig` includes. `make version` prints the current values. Clones need tags and full history (`git fetch --tags`; CI uses `fetch-depth: 0`).

## Cutting a release

1. Merge the work to `main`.
2. `make release LEVEL=minor` (or `major` / `patch`; `scripts/cut-release.sh <level> --dry-run` previews). It requires a clean tree, writes `CHANGELOG.md` from Conventional Commit subjects since the last tag ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)), commits it, and creates the annotated tag.
3. Pushing the branch and the tag is a manual step; the script only prints it.
4. `make archive` (signed). Uploading to TestFlight is a separate, manual decision; no script does it.

The app shows its version on the About screen.

## The kit version the app declares

The app is built against a kit of the same MINOR (while MAJOR is 0). The kit version it declares (`GreenfieldKitRequired` in Info.plist) is not typed in anywhere: `make generate` reads it from the kit checkout (`scripts/kit-version.sh`, which reads `ParrotKitInfo.version`) into the gitignored `Config/Kit.xcconfig`. A kit bump therefore needs no edit here; `KitCompatibilityTests` fails if the linked kit does not satisfy what was declared (a stale build of an older kit), and `make test-kit-version` tests the script.
