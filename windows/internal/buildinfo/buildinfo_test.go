package buildinfo

import (
	"os"
	"strings"
	"testing"

	"greenfield-inserter/internal/compat"
)

// The default minimum is the Mac daemon's declared one (the Makefile passes the file in; this is the fallback of a plain `go build`).
func TestDefaultMinClientIsTheMacDaemons(t *testing.T) {
	data, err := os.ReadFile("../../../mac/min-client-version")
	if err != nil {
		t.Skip("no mac/ beside windows/ (a copy of windows/ alone)")
	}
	if got := strings.TrimSpace(string(data)); got != MinClient {
		t.Errorf("mac/min-client-version says %s, buildinfo.MinClient defaults to %s", got, MinClient)
	}
}

func TestDefaultsAreValidVersions(t *testing.T) {
	if _, ok := compat.Parse(Version); !ok {
		t.Errorf("Version %q", Version)
	}
	if _, ok := compat.Parse(MinClient); !ok {
		t.Errorf("MinClient %q", MinClient)
	}
	if FullVersion() == "" {
		t.Errorf("FullVersion")
	}
}
