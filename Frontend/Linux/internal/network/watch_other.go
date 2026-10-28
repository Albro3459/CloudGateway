//go:build !linux

package network

import (
	"context"
	"errors"
)

func subscribe(context.Context, func()) error { return errors.ErrUnsupported }
