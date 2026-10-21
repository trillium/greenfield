SHELL := /bin/bash
BASE ?=
SCRIPT_FILES := $(wildcard scripts/*.sh) $(wildcard mac/scripts/*.sh) mac/install.sh $(wildcard tools/*/*.sh) $(wildcard pwa/test/*.sh) $(wildcard .githooks/*)

.PHONY: help windows pwa-serve test-pwa test-pwa-smoke logs test-ui test-kit-version test-pull-logs hooks check-commits test-commit-tooling test-mac check-parity release-check doctor generate build device-compile test archive archive-unsigned version release test-version check lint shell secrets hooks stub-receiver stub-receiver-test spike-build spike-audio core clean
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

doctor: ## check Xcode, tools, identity, signing prerequisites (SIGNING=1 makes signing items fatal)
	scripts/doctor.sh $(if $(SIGNING),--signing)
core: ## stage the sound detector libraries and the bundled model into .parrot-core (see scripts/fetch-core.sh)
	scripts/fetch-core.sh
generate: ## generate the .xcodeproj from project.yml
	PARROT_KIT_DIR="$$(scripts/kit-dir.sh)" xcodegen generate
build: ## simulator build, no signing
	scripts/build.sh
device-compile: ## iphoneos-SDK compile check, signing disabled
	scripts/build.sh --device
test: ## unit tests on an iOS simulator
	scripts/test.sh
test-ui: ## the accessibility audit (Apple's performAccessibilityAudit) on every tab and the first-run screen, on an iOS simulator
	scripts/test-ui.sh
version: ## print the version derived from git tags
	@scripts/version.sh --full; scripts/version.sh
release: ## cut a release: make release LEVEL=major|minor|patch (see docs/versioning.md)
	scripts/cut-release.sh $(LEVEL)
test-version: ## unit tests for scripts/version.sh
	scripts/test-version.sh
test-kit-version: ## unit tests for scripts/kit-version.sh
	scripts/test-kit-version.sh
archive: ## signed release archive (needs Apple signing; see docs/signing.md)
	scripts/archive.sh
archive-unsigned: ## unsigned archive: proves it compiles, cannot be uploaded
	SIGNING=none scripts/archive.sh

check: shell lint secrets test-version test-kit-version stub-receiver-test test test-ui test-mac windows test-pwa test-pull-logs check-commits test-commit-tooling $(if $(SIBLING),check-parity) ## the single green gate (phone, Mac, commit messages); must pass at every commit
shell: ## syntax + shellcheck
	@for f in $(SCRIPT_FILES); do bash -n "$$f" || exit 1; done
	shellcheck -x $(SCRIPT_FILES)
lint: ## swiftlint, warnings are errors
	swiftlint lint --strict --quiet
secrets: ## block signing material and credentials in tracked files
	scripts/check-secrets.sh --tracked
stub-receiver: ## run the stub Mac receiver (HOST=0.0.0.0 PORT=<port> KEY=secret LOG=file); see docs/mac-contract.md
	python3 tools/stub-receiver/receiver.py --host $(or $(HOST),127.0.0.1) $(if $(PORT),--port $(PORT)) $(if $(KEY),--key $(KEY)) $(if $(LOG),--log $(LOG))
stub-receiver-test: ## unit tests for the stub receiver
	python3 -m unittest discover -s tools/stub-receiver -q
spike-audio: ## make the spike's test audio with macOS `say` (gitignored); see docs/spike-dictation.md
	tools/spike/make_phrases.sh
spike-build: ## iphoneos compile check of the benchmark app (DictationSpike), signing disabled
	scripts/build.sh --device DictationSpike
hooks: ## enable .githooks and make sure commit-msg runs the commit message validator (never overwrites a foreign hook)
	@[ -n "$$(git config --local --get core.hooksPath)" ] || git config core.hooksPath .githooks
	scripts/install-hooks.sh
check-commits: ## validate every commit message since the base (BASE=<ref>, .commit-baseline or main); older history is exempt
	scripts/check-commits.sh $(BASE)
test-commit-tooling: ## tests for the validator, hook installer, check-commits, suggest-bump, env loader and parity check
	scripts/test-commit-tooling.sh
test-mac: ## unit tests of the Mac daemon
	$(MAKE) -C mac test
pwa-serve: ## serve the web app (pwa/) on this computer: on GREENFIELD_PWA_PORT, this computer only (docs/pwa.md has the phone recipe)
	@. scripts/load-env.sh && node pwa/server.mjs
test-pwa: ## unit tests of the web app and its server, with fakes (needs Node 20+; docs/pwa.md)
	node --test pwa/test/
test-pwa-smoke: ## the web app in a real Chrome against a real helper (needs chrome-devtools-axi and Go; docs/pwa.md)
	pwa/test/smoke.sh
windows: ## the Windows daemon: gofmt, go vet (native and windows/amd64, windows/arm64), tests with fakes, then both .exe files in build/windows (needs Go; docs/windows.md)
	$(MAKE) -C windows all
check-parity: ## compare the shared files with the sibling repo: make check-parity SIBLING=<path> (V=-v for the diff)
	scripts/check-parity.sh "$(SIBLING)" $(V)
logs: ## pull recent redacted logs, no cable: make logs TARGET=phone|macbook|mini0|trainer|all SINCE=30m OUT=<private folder> (docs/logs.md)
	scripts/pull-logs.sh $(if $(TARGET),--target $(TARGET)) $(if $(SINCE),--since $(SINCE)) $(if $(TAIL),--tail $(TAIL)) $(if $(OUT),--out $(OUT))
test-pull-logs: ## tests for scripts/pull-logs.sh (stubbed devicectl, ssh and daemon)
	scripts/test-pull-logs.sh
release-check: ## suggested semver bump since the last tag, and whether its changelog section exists
	scripts/release.sh
clean:
	rm -rf build *.xcodeproj
