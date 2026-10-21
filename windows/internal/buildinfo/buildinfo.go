// Package buildinfo holds what the Makefile stamps into the binary from the git tags (scripts/version.sh), so no version is
// typed in by hand. An unstamped build (plain `go build`) says 0.0.0, which the phone reports as "update the computer's daemon".
package buildinfo

// These are set with -ldflags "-X greenfield-inserter/internal/buildinfo.Version=..." by windows/Makefile.
var (
	// Version is MAJOR.MINOR.PATCH, the compatibility contract (docs/mac-contract.md).
	Version = "0.0.0"
	// Full is the human version, e.g. 0.4.1+3.gabc1234.
	Full = ""
	// Commit is the short commit the binary was built from.
	Commit = "unknown"
	// MinClient is the oldest app this daemon accepts. The Mac daemon's file mac/min-client-version is the one source (the Makefile
	// passes it in); this default is checked against that file by a test.
	MinClient = "0.2.0"
)

// FullVersion is Full, or Version when no human version was stamped.
func FullVersion() string {
	if Full != "" {
		return Full
	}
	return Version
}
