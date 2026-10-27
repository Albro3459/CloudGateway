//go:build !linux

package network

import (
	"errors"
	"syscall"
)

func markControl(uint32) func(network, address string, c syscall.RawConn) error {
	return func(string, string, syscall.RawConn) error { return errors.ErrUnsupported }
}
