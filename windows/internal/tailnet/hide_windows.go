//go:build windows

package tailnet

import (
	"os/exec"
	"syscall"
)

// hideWindow keeps a console window from flashing when the daemon (which may have no console) starts the tailscale tool.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}
