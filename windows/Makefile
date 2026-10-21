# greenfield-inserter for Windows: the Windows twin of the Mac daemon in ../mac. Pure Go, no cgo, no third-party modules.
# Everything except typing into a real window is tested here, on any machine (docs/windows.md).
GO ?= go
PKG := greenfield-inserter
OUT ?= ../build/windows
ARCHES := amd64 arm64
ROOT := $(abspath ..)

# The version comes from the git tags (../docs/versioning.md); nothing types it in. The oldest app accepted is the Mac daemon's file:
# one contract line, one declaration.
VERSION := $(shell ../scripts/version.sh --marketing 2>/dev/null || echo 0.0.0)
FULL    := $(shell ../scripts/version.sh --full 2>/dev/null || echo 0.0.0)
COMMIT  := $(shell git -C .. rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
MINCLIENT := $(shell tr -d '[:space:]' < ../mac/min-client-version 2>/dev/null)
LDFLAGS := -s -w -X $(PKG)/internal/buildinfo.Version=$(VERSION) -X $(PKG)/internal/buildinfo.Full=$(FULL) -X $(PKG)/internal/buildinfo.Commit=$(COMMIT) $(if $(MINCLIENT),-X $(PKG)/internal/buildinfo.MinClient=$(MINCLIENT))

.PHONY: all check fmt-check vet test cross-vet build run clean

all: check build ## format, vet (native and both Windows targets), tests, then both .exe files in $(OUT)

check: fmt-check vet cross-vet test ## everything that can run on a Mac

fmt-check:
	@bad="$$(gofmt -l .)"; if [ -n "$$bad" ]; then echo "gofmt needed:"; echo "$$bad"; exit 1; fi

vet:
	$(GO) vet ./...

cross-vet:
	@for arch in $(ARCHES); do echo "go vet GOOS=windows GOARCH=$$arch"; GOOS=windows GOARCH=$$arch CGO_ENABLED=0 $(GO) vet ./... || exit 1; done

test:
	$(GO) test -race -count=1 ./...

build: ## windows/amd64 and windows/arm64 .exe files (static: CGO_ENABLED=0)
	@mkdir -p $(OUT)
	@for arch in $(ARCHES); do \
	  echo "build $(OUT)/greenfield-inserter-windows-$$arch.exe ($(FULL))"; \
	  GOOS=windows GOARCH=$$arch CGO_ENABLED=0 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o $(OUT)/greenfield-inserter-windows-$$arch.exe ./cmd/greenfield-inserter || exit 1; \
	done

run: ## run the daemon from this machine without typing anything (a dry run, for trying the connection from the phone)
	$(GO) run -ldflags '$(LDFLAGS)' ./cmd/greenfield-inserter serve --dry-run --log-stderr

clean:
	rm -rf $(OUT)
