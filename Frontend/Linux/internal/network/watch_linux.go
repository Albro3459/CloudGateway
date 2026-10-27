//go:build linux

package network

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"
)

// rtnetlinkGroups are the legacy group bits for RTMGRP_LINK, IPV4_IFADDR,
// IPV4_ROUTE, IPV4_RULE, IPV6_IFADDR, IPV6_ROUTE, and 1<<(RTNLGRP_IPV6_RULE-1).
// syscall has no names for them
const rtnetlinkGroups = 0x1 | 0x10 | 0x40 | 0x80 | 0x100 | 0x400 | 0x40000

func subscribe(ctx context.Context, notify func()) error {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, syscall.NETLINK_ROUTE)
	if err != nil {
		return fmt.Errorf("network: netlink socket: %w", err)
	}
	if err := syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: rtnetlinkGroups}); err != nil {
		_ = syscall.Close(fd)
		return fmt.Errorf("network: netlink bind: %w", err)
	}
	// A nonblocking descriptor makes the file pollable, so Close ends a pending Read
	file := os.NewFile(uintptr(fd), "rtnetlink")
	context.AfterFunc(ctx, func() { _ = file.Close() })
	go func() {
		buffer := make([]byte, 1<<16)
		for {
			_, err := file.Read(buffer)
			// ENOBUFS means events were dropped, which still calls for a reconcile.
			// Other errors end the subscription, so reconcile once and leave the
			// periodic tick in charge
			if err != nil && !errors.Is(err, syscall.ENOBUFS) {
				_ = file.Close()
				if ctx.Err() == nil {
					notify()
				}
				return
			}
			notify()
		}
	}()
	return nil
}
