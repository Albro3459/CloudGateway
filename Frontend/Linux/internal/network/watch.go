package network

import (
	"context"
	"time"
)

const defaultWatchInterval = 30 * time.Second

// Watch signals when owned state may need Reconcile: on rtnetlink link,
// address, route, and rule events, and every interval for changes netlink does
// not report, such as resolver settings or a flushed nftables ruleset. The
// channel holds at most one pending signal and is never closed. When the netlink
// subscription fails, the channel still ticks and Watch returns the error. An
// interval of zero or less means defaultWatchInterval
func Watch(ctx context.Context, interval time.Duration) (<-chan struct{}, error) {
	if interval <= 0 {
		interval = defaultWatchInterval
	}
	signals := make(chan struct{}, 1)
	notify := func() {
		select {
		case signals <- struct{}{}:
		default:
		}
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				notify()
			}
		}
	}()
	return signals, subscribe(ctx, notify)
}
