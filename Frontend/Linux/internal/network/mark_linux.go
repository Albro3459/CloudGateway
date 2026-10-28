//go:build linux

package network

import "syscall"

// markControl sets SO_MARK so the socket skips the tunnel rule. It needs CAP_NET_ADMIN
func markControl(mark uint32) func(network, address string, c syscall.RawConn) error {
	return func(_, _ string, c syscall.RawConn) error {
		var markErr error
		err := c.Control(func(fd uintptr) {
			markErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_MARK, int(mark))
		})
		if err != nil {
			return err
		}
		return markErr
	}
}
