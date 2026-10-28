//go:build !linux

package daemon

import (
	"errors"
	"net"
	"syscall"
)

// peerCredentials fails closed off Linux, where the daemon never runs
func peerCredentials(*net.UnixConn) (Peer, error) {
	return Peer{}, errors.New("peer credentials are only available on Linux")
}

func Harden() error {
	syscall.Umask(0o077)
	return syscall.Setrlimit(syscall.RLIMIT_CORE, &syscall.Rlimit{})
}
