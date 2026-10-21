# Keeping sibling repos identical

Two repos share the commit and versioning tooling. They must never end up with two close-but-not-exact copies, so the shared
files are listed in `scripts/parity-manifest.txt` and compared byte for byte:

```
make check-parity SIBLING=<path to the other repo>      # add V=-v for the full diff
```

It prints `DRIFT`, `ONLY-HERE` or `ONLY-SIBLING` for every file that differs, with a count of changed lines, and exits non-zero
on any drift. It is not part of `make check` because it needs the other checkout.

## Changing a shared file

1. Make the change in one repo, with its tests, and get that repo's `make check` green.
2. Copy the file(s) to the same path in the sibling: `cp scripts/check-commit-msg.sh ../other/scripts/`. Do not edit the
   copy by hand.
3. Run `make check-parity SIBLING=../other` from either side until it reports identical, and `make check` in the sibling.
4. Commit in both repos. The commit messages reference each other (`sync with <repo>`).

A new shared file is added to `scripts/parity-manifest.txt` in both repos in the same change (the manifest is itself shared).

## What is not shared

Anything with a project name or port in it stays out of the manifest: `.env.example` and any xcconfig, the `Makefile`,
`scripts/release.sh` (it knows where each project keeps its changelog), `.githooks/` or other hook wiring, README and
project docs. Shared files must stay free of project names and port numbers, so they work in both repos unchanged.
Ports come from `.env` (or xcconfig) in each repo, never from a shared file.
