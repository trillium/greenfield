# greenfield-inserter: receives text over the tailnet and inserts it at the cursor.
SWIFT ?= swift
PORT  ?= 47821

.PHONY: build test run key check insert-test permissions install uninstall status logs clean

build:
	$(SWIFT) build -c release

test:
	$(SWIFT) test

# Build and run in the foreground on the tailnet address (Ctrl-C to stop).
run: build
	.build/release/greenfield-inserter serve --port $(PORT) --log-stderr

# Create this Mac's key and show it once. Refuses to overwrite; use `make key FORCE=--force` to rotate.
key: build
	.build/release/greenfield-inserter key create $(FORCE)

# From the Mac that holds the keys (see `greenfield-inserter macs add`): status of every remembered Mac.
check: build
	.build/release/greenfield-inserter macs check

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
