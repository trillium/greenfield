# Commit messages and versions

Every commit subject follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), and the type decides the
[semver](https://semver.org/) bump of the next release. Nobody edits a version number by hand; releases are git tags `vX.Y.Z`.

```
type(scope)!: subject

optional body, after one blank line

BREAKING CHANGE: what breaks and what to do about it
```

## Rules (enforced by `scripts/check-commit-msg.sh`)

- **type** is one of `feat fix docs chore refactor test perf build ci revert`.
- **scope** is optional: lowercase letters, digits, `.`, `_`, `/`, `-` (`feat(mac): ...`).
- **subject** starts lowercase (an all-caps acronym such as `HTTP` is fine), is in the imperative mood (`add`, not `added`,
  `adds` or `adding`), does not end with a period, and the whole first line is at most 72 characters.
- **breaking** changes are marked with `!` before the colon (`feat(api)!: drop v1`), or by a `BREAKING CHANGE: ...` footer, or both.
- A body, if any, starts after one blank line.
- **Merge commits are exempt**, and so is all history before the base: `make check-commits` looks only at the commits you are
  adding. The base is `BASE=<ref>` if given, else the ref or sha in a `.commit-baseline` file at the repo root, else `main`
  (then `origin/main`). A repo whose older history does not follow the convention records the last exempt commit there.

The imperative check is a heuristic on the first word (it rejects `-ed`, `-ing` and third-person `-s` forms, with a short list
of exceptions such as `embed` and `string`). If it rejects a good verb, reword the subject.

## What each type does to the version

| Type | Bump |
|---|---|
| `feat` | minor |
| `fix`, `perf` | patch |
| breaking (`!` or `BREAKING CHANGE:` footer), any type | major; **minor while MAJOR is 0** |
| `docs`, `chore`, `refactor`, `test`, `build`, `ci`, `revert` | no bump |

The highest bump among the commits since the last tag wins. 1.0.0 is a deliberate decision, never a side effect of a breaking
commit. `scripts/suggest-bump.sh` prints the suggestion; `scripts/release.sh` shows it and refuses to go on without a
changelog section for the version.

## Using it

```
make hooks            # once per clone: installs the commit-msg hook (never overwrites a hook that is not ours)
make check-commits    # validate every commit since the base (see above); part of make check
make test-commit-tooling   # the validator's own tests, good and bad examples
scripts/check-commit-msg.sh -m "fix(mac): reject empty text"    # try a message
```

Fix a rejected commit before it is shared: `git commit --amend` for the last one, `git rebase -i <base>` and reword for older
ones. Existing history is not rewritten.
