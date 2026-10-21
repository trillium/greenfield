# greenfield-inserter: receives text over the tailnet and inserts it at the cursor.
SWIFT ?= swift
PORT  ?= 47821

.PHONY: onboard ready stamp restart update verify-running version build test run key check health doctor selftest insert-test permissions install uninstall status logs clean

# The whole onboarding in one command: install the signed build, start it, guide the Accessibility step, end "ready".
onboard:
	./install.sh

# "Am I ready?": ready, or exactly one next step in plain words.
ready: build
	.build/release/greenfield-inserter ready

# The daemon's version comes from the git tags (../docs/versioning.md); nothing types it in.
stamp:
	scripts/stamp-version.sh

version: build
	.build/release/greenfield-inserter version

build: stamp
	$(SWIFT) build -c release

test: stamp
	$(SWIFT) test

# Restart the installed agent (bootout + bootstrap) and check the running build is the installed file.
restart: build
	.build/release/greenfield-inserter restart

verify-running: build
	.build/release/greenfield-inserter verify-running

# Install a new signed build with verification and rollback: make update FROM=/path/to/signed/greenfield-inserter
update: build
	.build/release/greenfield-inserter update --from $(FROM)

# Build and run in the foreground on the tailnet address (Ctrl-C to stop).
run: build
	.build/release/greenfield-inserter serve --port $(PORT) --log-stderr

# Create this Mac's key and show it once. Refuses to overwrite; use `make key FORCE=--force` to rotate.
key: build
	.build/release/greenfield-inserter key create $(FORCE)

# From the Mac that holds the keys (see `greenfield-inserter macs add`): status of every remembered Mac.
check: build
	.build/release/greenfield-inserter macs check

# This Mac's daemon: fast yes/no (health) or what to fix and how (doctor). `greenfield-inserter macs health|doctor` does every remembered Mac.
health: build
	.build/release/greenfield-inserter health

doctor: build
	.build/release/greenfield-inserter doctor

# Open a test window and push a test string and a Return through this Mac's own daemon; PASS or FAIL with the fix.
selftest: build
	.build/release/greenfield-inserter selftest

# Insert a harmless test string into the focused app of one Mac: make insert-test MAC=alias
insert-test: build
	.build/release/greenfield-inserter macs test $(MAC)

# Check Accessibility and make macOS show its permission prompt if it is missing.
permissions: build
	.build/release/greenfield-inserter permissions

# Install as a launchd agent: starts at login, restarts on crash.
install:
	PORT=$(PORT) scripts/agent.sh install

uninstall:
	scripts/agent.sh uninstall

status:
	scripts/agent.sh status

logs:
	scripts/agent.sh logs

clean:
	$(SWIFT) package clean
