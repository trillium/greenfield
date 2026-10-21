// Command greenfield-inserter is the Windows input daemon of Greenfield: the phone sends text over the tailnet and this program types
// it at the cursor of the focused app. It speaks the same contract as the Mac daemon (docs/mac-contract.md); see docs/windows.md.
package main

import (
	"os"

	"greenfield-inserter/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], cli.Deps{}))
}
