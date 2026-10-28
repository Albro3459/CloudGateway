package ipc

// DoctorRequirement decides how a failed check affects the doctor exit code:
// setup failures exit with the check's failure code, online failures exit as
// network_unavailable, and optional failures never fail doctor
type DoctorRequirement string

const (
	DoctorSetup    DoctorRequirement = "setup"
	DoctorOnline   DoctorRequirement = "online"
	DoctorOptional DoctorRequirement = "optional"
)

// DoctorProbe is one doctor check. The CLI runs local probes itself and asks
// the daemon for the rest by name with ActionDiagnostics and Request.Probe
//
// Probes only read evidence. They never log in, refresh, install, repair, or
// change the tunnel
type DoctorProbe struct {
	Name        string
	Requirement DoctorRequirement
	Local       bool
	Meaning     string
}

// DoctorProbes runs in order. The daemon answers each name with Reply.Check,
// whose Name matches the probe, within five seconds. A FailureCode must be a
// public CLI error code
var DoctorProbes = []DoctorProbe{
	{Name: "installation", Requirement: DoctorSetup, Local: true,
		Meaning: "The installed release under /opt/cloudgateway/current is present and readable. Fails with installation_required"},
	{Name: "daemon", Requirement: DoctorSetup, Local: true,
		Meaning: "The daemon socket accepts this user, completes the handshake, and speaks this CLI's IPC version"},
	{Name: "network_tools", Requirement: DoctorSetup,
		Meaning: "wg, ip, and nft are installed and the kernel provides WireGuard. Fails with setup_required"},
	{Name: "dns_policy", Requirement: DoctorSetup,
		Meaning: "Passes in Mesh unless selected Full has a DNS-readiness warning. In Full, fails with setup_required when the resolver cannot carry VPN DNS, " +
			"and with vpn_failed after a resolver-policy failure tore the tunnel down"},
	{Name: "resolver", Requirement: DoctorOptional,
		Meaning: "systemd-resolved is active, /etc/resolv.conf uses its stub, and links have upstream DNS servers. Full mode needs it"},
	{Name: "credentials", Requirement: DoctorOptional,
		Meaning: "Saved credentials are readable, without restoring or exchanging them"},
	{Name: "access", Requirement: DoctorOptional,
		Meaning: "The account access the daemon already observed, without verifying it again"},
	{Name: "inventory", Requirement: DoctorOptional,
		Meaning: "The most recent retained inventory failure, as a warning"},
	{Name: "network_path", Requirement: DoctorOnline,
		Meaning: "The host has a usable default route"},
	{Name: "dns", Requirement: DoctorOnline,
		Meaning: "The CloudGateway site hostname resolves"},
	{Name: "https", Requirement: DoctorOnline,
		Meaning: "The CloudGateway API returns a successful HTTPS response, without following redirects"},
	{Name: "server", Requirement: DoctorOptional,
		Meaning: "The connected server answers through the tunnel. A warning suggests: Run: cloudgateway refresh"},
	{Name: "service", Requirement: DoctorOptional,
		Meaning: "The known regional API reports healthy with a matching region ID"},
}
