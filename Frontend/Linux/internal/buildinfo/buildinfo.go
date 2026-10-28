// Package buildinfo holds release identity, public service configuration, and
// install paths. Release builds set the variables with -ldflags -X
package buildinfo

var (
	// Version is the Linux release version. JSON version and build both use it
	Version = "1.0.0"

	// Public Firebase web configuration. These identify the project and are
	// not secrets. Release builds inject the real values
	FirebaseAPIKey     = ""
	FirebaseProjectID  = ""
	FirebaseDatabaseID = "(default)"

	// Origin is the CloudGateway site host. The API lives at api.<origin> and
	// regional APIs at <regionId>.<origin>
	Origin = "gocloudlaunch.com"
)

// Build mirrors Version since Linux releases have no separate build counter
func Build() string { return Version }

const (
	InstallRoot  = "/opt/cloudgateway"
	ReleasesDir  = InstallRoot + "/releases"
	CurrentLink  = InstallRoot + "/current"
	ConfigDir    = "/etc/cloudgateway"
	DaemonConfig = ConfigDir + "/daemon.json"
	StateDir     = "/var/lib/cloudgateway"
	RuntimeDir   = "/run/cloudgateway"
	SocketPath   = RuntimeDir + "/cloudgatewayd.sock"
	ServiceName  = "cloudgatewayd.service"
	DeviceName   = "CloudGateway for Linux"
)
