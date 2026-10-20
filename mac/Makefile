# greenfield-inserter: receives text over the tailnet and inserts it at the cursor.
SWIFT ?= swift
PORT  ?= 47821

.PHONY: build test run key permissions install uninstall status logs clean

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
