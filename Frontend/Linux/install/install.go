// Package install embeds the installer and systemd unit so the release tool
// packages the exact files in this directory
package install

import _ "embed"

//go:embed install.sh
var Script []byte

//go:embed cloudgatewayd.service
var Unit []byte
