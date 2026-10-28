package network

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Tools the package runs. SystemExecutor finds them only in systemDirs
const (
	ToolIP         = "ip"
	ToolWG         = "wg"
	ToolNft        = "nft"
	ToolResolvectl = "resolvectl"
	ToolBusctl     = "busctl"
)

// Executor is the boundary to the host. Run never goes through a shell, and
// stdin is the only path for key material
type Executor interface {
	Run(ctx context.Context, tool string, args []string, stdin []byte) ([]byte, error)
	Available(tool string) bool
	ReadFile(name string) ([]byte, error)
	WriteFile(name string, data []byte) error
}

var systemDirs = []string{"/usr/sbin", "/usr/bin", "/sbin", "/bin"}

const commandTimeout = 15 * time.Second

// CommandError carries the tool, its arguments, and exit status. Arguments never
// hold secrets. Output is dropped since wg echoes rejected config lines, keys included
type CommandError struct {
	Tool     string
	Args     []string
	ExitCode int
}

func (e *CommandError) Error() string {
	return fmt.Sprintf("network: %s %s exited with status %d", e.Tool, strings.Join(e.Args, " "), e.ExitCode)
}

// SystemExecutor runs root-owned system tools directly
type SystemExecutor struct{}

func (SystemExecutor) path(tool string) (string, error) {
	switch tool {
	case ToolIP, ToolWG, ToolNft, ToolResolvectl, ToolBusctl:
	default:
		return "", fmt.Errorf("network: unknown tool %q", tool)
	}
	for _, dir := range systemDirs {
		path := filepath.Join(dir, tool)
		info, err := os.Stat(path)
		if err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 && info.Mode().Perm()&0o022 == 0 {
			return path, nil
		}
	}
	return "", fmt.Errorf("%w: %s", ErrToolMissing, tool)
}

func (e SystemExecutor) Available(tool string) bool {
	_, err := e.path(tool)
	return err == nil
}

func (e SystemExecutor) Run(ctx context.Context, tool string, args []string, stdin []byte) ([]byte, error) {
	path, err := e.path(tool)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = []string{"LC_ALL=C", "PATH=/usr/sbin:/usr/bin:/sbin:/bin"}
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	err = cmd.Run()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("network: %s %s: %w", tool, strings.Join(args, " "), ctx.Err())
	}
	if err != nil {
		code := -1
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code = exitErr.ExitCode()
		}
		return nil, &CommandError{Tool: tool, Args: args, ExitCode: code}
	}
	return stdout.Bytes(), nil
}

func (SystemExecutor) ReadFile(name string) ([]byte, error) { return os.ReadFile(name) }

// WriteFile writes without create or truncate, which suits /proc/sys
func (SystemExecutor) WriteFile(name string, data []byte) error {
	file, err := os.OpenFile(name, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

type command struct {
	tool  string
	args  []string
	stdin []byte
}

func ipCommand(args ...string) command { return command{tool: ToolIP, args: args} }

func (m *Manager) run(ctx context.Context, c command) ([]byte, error) {
	return m.exec.Run(ctx, c.tool, c.args, c.stdin)
}

// runAll stops at the first failure
func (m *Manager) runAll(ctx context.Context, commands []command) error {
	for _, c := range commands {
		if _, err := m.run(ctx, c); err != nil {
			return err
		}
	}
	return nil
}
