SHELL := /bin/bash
SCRIPT_FILES := $(wildcard scripts/*.sh) $(wildcard tools/*/*.sh) $(wildcard .githooks/*)

.PHONY: help doctor generate build device-compile test archive archive-unsigned version release test-version check lint shell secrets hooks stub-receiver stub-receiver-test spike-build spike-audio core clean
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

doctor: ## check Xcode, tools, identity, signing prerequisites (SIGNING=1 makes signing items fatal)
	scripts/doctor.sh $(if $(SIGNING),--signing)
core: ## stage the sound detector libraries and the bundled model into .parrot-core (see scripts/fetch-core.sh)
	scripts/fetch-core.sh
generate: ## generate the .xcodeproj from project.yml
	xcodegen generate
build: ## simulator build, no signing
	scripts/build.sh
device-compile: ## iphoneos-SDK compile check, signing disabled
	scripts/build.sh --device
test: ## unit tests on an iOS simulator
	scripts/test.sh
version: ## print the version derived from git tags
	@scripts/version.sh --full; scripts/version.sh
release: ## cut a release: make release LEVEL=major|minor|patch (see docs/versioning.md)
	scripts/release.sh $(LEVEL)
test-version: ## unit tests for scripts/version.sh
	scripts/test-version.sh
archive: ## signed release archive (needs Apple signing; see docs/signing.md)
	scripts/archive.sh
archive-unsigned: ## unsigned archive: proves it compiles, cannot be uploaded
	SIGNING=none scripts/archive.sh

check: shell lint secrets test-version stub-receiver-test test ## the single green gate; must pass at every commit
shell: ## syntax + shellcheck
	@for f in $(SCRIPT_FILES); do bash -n "$$f" || exit 1; done
	shellcheck -x $(SCRIPT_FILES)
lint: ## swiftlint, warnings are errors
	swiftlint lint --strict --quiet
secrets: ## block signing material and credentials in tracked files
	scripts/check-secrets.sh --tracked
stub-receiver: ## run the stub Mac receiver (HOST=0.0.0.0 PORT=47821 KEY=secret LOG=file); see docs/mac-contract.md
	python3 tools/stub-receiver/receiver.py --host $(or $(HOST),127.0.0.1) --port $(or $(PORT),47821) $(if $(KEY),--key $(KEY)) $(if $(LOG),--log $(LOG))
stub-receiver-test: ## unit tests for the stub receiver
	python3 -m unittest discover -s tools/stub-receiver -q
spike-audio: ## make the spike's test audio with macOS `say` (gitignored); see docs/spike-dictation.md
	tools/spike/make_phrases.sh
spike-build: ## iphoneos compile check of the benchmark app (DictationSpike), signing disabled
	scripts/build.sh --device DictationSpike
hooks: ## enable .githooks for this clone
	git config core.hooksPath .githooks
clean:
	rm -rf build *.xcodeproj
