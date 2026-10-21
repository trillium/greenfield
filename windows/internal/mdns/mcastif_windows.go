//go:build windows

package mdns

import (
	"net"
	"syscall"
)

// setMulticastInterface makes the socket send multicast out of the interface that owns ip.
func setMulticastInterface(c *net.UDPConn, ip [4]byte) error {
	raw, err := c.SyscallConn()
	if err != nil {
		return err
	}
	var serr error
	if err := raw.Control(func(fd uintptr) {
		serr = syscall.SetsockoptInet4Addr(syscall.Handle(fd), syscall.IPPROTO_IP, syscall.IP_MULTICAST_IF, ip)
	}); err != nil {
		return err
	}
	return serr
}
