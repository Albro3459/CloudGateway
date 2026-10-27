//go:build linux

package cli

import (
	"bytes"
	"syscall"
	"unsafe"
)

func ioctl(fd int, request uintptr, arg unsafe.Pointer) bool {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, uintptr(arg))
	return errno == 0
}

func isTerminal(fd int) bool {
	var settings syscall.Termios
	return ioctl(fd, syscall.TCGETS, unsafe.Pointer(&settings))
}

// terminalInput polls shortcut keys from stdin and restores the terminal on close. It uses
// non-canonical reads with VMIN and VTIME at 0, never O_NONBLOCK, since a tty's open file
// description is shared with stdout and nonblocking writes could fail with EAGAIN
type terminalInput struct {
	saved *syscall.Termios
}

func (t *terminalInput) width() int {
	var size struct{ rows, cols, xPixels, yPixels uint16 }
	if !ioctl(1, syscall.TIOCGWINSZ, unsafe.Pointer(&size)) {
		return 0
	}
	return int(size.cols)
}

func (t *terminalInput) start(shortcuts bool) bool {
	if !shortcuts || !isTerminal(0) || !isTerminal(1) {
		return false
	}
	var group int32
	if !ioctl(0, syscall.TIOCGPGRP, unsafe.Pointer(&group)) || int(group) != syscall.Getpgrp() {
		return false
	}
	var settings syscall.Termios
	if !ioctl(0, syscall.TCGETS, unsafe.Pointer(&settings)) {
		return false
	}
	saved := settings
	t.saved = &saved
	settings.Lflag &^= syscall.ICANON | syscall.ECHO
	settings.Cc[syscall.VMIN], settings.Cc[syscall.VTIME] = 0, 0
	if !ioctl(0, syscall.TCSETS, unsafe.Pointer(&settings)) {
		t.restore()
		return false
	}
	return true
}

// readKeys returns at once. A zero-byte read only means no key is waiting
func (t *terminalInput) readKeys() []byte {
	if t.saved == nil {
		return nil
	}
	buffer := make([]byte, 64)
	count, err := syscall.Read(0, buffer)
	if count > 0 {
		keys := buffer[:count]
		// Ctrl-D ends shortcut input and gives the terminal back
		if bytes.IndexByte(keys, 4) >= 0 {
			t.restore()
		}
		return bytes.ReplaceAll(keys, []byte{4}, nil)
	}
	if err != nil && err != syscall.EAGAIN && err != syscall.EINTR {
		t.restore()
	}
	return nil
}

func (t *terminalInput) restore() {
	if t.saved == nil {
		return
	}
	ioctl(0, syscall.TCSETS, unsafe.Pointer(t.saved))
	t.saved = nil
}

func (t *terminalInput) close() { t.restore() }
