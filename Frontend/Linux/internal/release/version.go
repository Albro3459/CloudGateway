// Package release names Linux release assets and reads the identity of the
// installed release
package release

import "strings"

const UnitName = "cloudgatewayd.service"

var (
	Arches      = []string{"amd64", "arm64"}
	Executables = []string{"bin/cloudgateway", DaemonPath}
)

func ArchiveName(version, arch string) string {
	return "cloudgateway-linux-" + version + "-" + arch + ".tar.gz"
}

// ValidVersion accepts release versions in MAJOR.MINOR.PATCH form without
// leading zeros, pre-release, or build metadata, and up to 18 digits per part,
// which install.sh matches
func ValidVersion(version string) bool {
	fields := strings.Split(version, ".")
	if len(fields) != 3 {
		return false
	}
	for _, field := range fields {
		if field == "" || len(field) > 18 || len(field) > 1 && field[0] == '0' || strings.TrimLeft(field, "0123456789") != "" {
			return false
		}
	}
	return true
}
