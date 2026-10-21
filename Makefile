SHELL := /bin/bash
BASE ?=

.PHONY: help hooks check check-commits test-commit-tooling test-mac check-parity release-check shell
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

hooks: ## enable .githooks and make sure commit-msg runs the commit message validator (never overwrites a foreign hook)
	@[ -n "$$(git config --local --get core.hooksPath)" ] || git config core.hooksPath .githooks
	scripts/install-hooks.sh
check-commits: ## validate every commit message since the base (BASE=<ref>, .commit-baseline or main); older history is exempt
	scripts/check-commits.sh $(BASE)
test-commit-tooling: ## tests for the validator, hook installer, check-commits, suggest-bump, env loader and parity check
	scripts/test-commit-tooling.sh
test-mac: ## unit tests of the Mac daemon
	$(MAKE) -C mac test
shell: ## syntax-check the shell scripts (and shellcheck when installed)
	@for f in scripts/*.sh mac/scripts/*.sh .githooks/*; do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck -x scripts/*.sh mac/scripts/*.sh; else echo "shellcheck not installed; skipped"; fi
check: shell check-commits test-commit-tooling test-mac ## the single green gate
check-parity: ## compare the shared files with the sibling repo: make check-parity SIBLING=<path> (V=-v for the diff)
	scripts/check-parity.sh "$(SIBLING)" $(V)
release-check: ## suggested semver bump since the last tag, and whether its changelog section exists
	scripts/release.sh
