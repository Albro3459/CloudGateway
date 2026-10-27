package daemon

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"syscall"
)

// Config is /etc/cloudgateway/daemon.json, written by the installer
type Config struct {
	// OperatorUID is the one local user, besides root, allowed on the socket
	OperatorUID uint32
}

// LoadConfig refuses a missing, malformed, non-root-owned, or group/world writable file
func LoadConfig(path string) (Config, error) { return loadConfig(path, 0) }

func loadConfig(path string, owner uint32) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Config{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	switch {
	case !info.Mode().IsRegular():
		return Config{}, fmt.Errorf("%s is not a regular file", path)
	case !ok || stat.Uid != owner:
		return Config{}, fmt.Errorf("%s must be owned by uid %d", path, owner)
	case info.Mode().Perm()&0o022 != 0:
		return Config{}, fmt.Errorf("%s must not be group or world writable", path)
	}
	data, err := io.ReadAll(io.LimitReader(file, 4<<10+1))
	if err != nil {
		return Config{}, err
	}
	var raw struct {
		OperatorUID *uint32 `json:"operatorUid"`
	}
	// chown treats uid 0xFFFFFFFF as no change
	if len(data) > 4<<10 || json.Unmarshal(data, &raw) != nil || raw.OperatorUID == nil || *raw.OperatorUID == math.MaxUint32 {
		return Config{}, fmt.Errorf("%s is malformed", path)
	}
	return Config{OperatorUID: *raw.OperatorUID}, nil
}
