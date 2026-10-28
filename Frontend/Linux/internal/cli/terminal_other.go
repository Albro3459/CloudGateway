//go:build !linux

package cli

// Other platforms only build the CLI for host-free tests, so the terminal stays plain

func isTerminal(int) bool { return false }

type terminalInput struct{}

func (*terminalInput) start(bool) bool  { return false }
func (*terminalInput) readKeys() []byte { return nil }
func (*terminalInput) width() int       { return 0 }
func (*terminalInput) close()           {}
