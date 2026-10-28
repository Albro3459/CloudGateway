package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/network"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/store"
)

const (
	refreshSuggestion = "Run: cloudgateway refresh"
	probeTimeout      = 4500 * time.Millisecond
)

func check(name string, status ipc.DoctorStatus, evidence, suggestion, failureCode string) *ipc.DoctorCheck {
	result := &ipc.DoctorCheck{Name: name, Status: status, Evidence: evidence}
	if suggestion != "" {
		result.Suggestion = &suggestion
	}
	if failureCode != "" {
		result.FailureCode = &failureCode
	}
	return result
}

// diagnose answers one daemon-side doctor probe within probeTimeout, inside
// the CLI's five second budget. Probes only read evidence: they never sign
// in, refresh, repair, or change the tunnel
func (c *Controller) diagnose(parent context.Context, name string) *ipc.DoctorCheck {
	ctx, cancel := context.WithTimeout(parent, probeTimeout)
	defer cancel()
	result := make(chan *ipc.DoctorCheck, 1)
	go func() { result <- c.runProbe(ctx, name) }()
	select {
	case answer := <-result:
		return answer
	case <-ctx.Done():
		return check(name, ipc.DoctorUnknown, "The daemon did not finish this check in time", "", "")
	}
}

func (c *Controller) runProbe(ctx context.Context, name string) *ipc.DoctorCheck {
	switch name {
	case "network_tools":
		return c.networkToolsCheck()
	case "dns_policy":
		return c.dnsPolicyCheck(ctx)
	case "resolver":
		return c.resolverCheck(ctx)
	case "credentials":
		return c.credentialsCheck()
	case "access":
		return c.accessCheck()
	case "inventory":
		c.mu.Lock()
		failure := c.inventoryFailure
		c.mu.Unlock()
		if failure == "" {
			return check(name, ipc.DoctorPass, "No inventory failure retained by the daemon", "", "")
		}
		return check(name, ipc.DoctorWarning, "Most recent inventory failure: "+failure+
			". This is retained evidence, not a current reachability check", refreshSuggestion, "")
	case "network_path":
		return c.networkPathCheck(ctx)
	case "dns":
		addrs, err := c.lookup(ctx, buildinfo.Origin)
		if err != nil || len(addrs) == 0 {
			return check(name, ipc.DoctorFail, "The CloudGateway site hostname did not resolve", "", "")
		}
		return check(name, ipc.DoctorPass, "The CloudGateway site hostname resolved", "", "")
	case "https":
		status, _, err := c.httpGet(ctx, "https://api."+buildinfo.Origin+"/api/health")
		switch {
		case err != nil:
			return check(name, ipc.DoctorFail, "CloudGateway API HTTPS reachability could not be established", "", "")
		case status < 200 || status > 299:
			return check(name, ipc.DoctorFail, "The CloudGateway API returned an unsuccessful HTTPS response", "", "")
		}
		return check(name, ipc.DoctorPass, "The CloudGateway API returned a successful HTTPS response", "", "")
	case "server":
		return c.serverCheck(ctx)
	case "service":
		return c.serviceCheck(ctx)
	}
	return check(name, ipc.DoctorUnknown, "The daemon does not run this check", "", "")
}

func (c *Controller) networkToolsCheck() *ipc.DoctorCheck {
	var missing []string
	for _, tool := range []string{network.ToolWG, network.ToolIP, network.ToolNft} {
		if !c.exec.Available(tool) {
			missing = append(missing, tool)
		}
	}
	if !c.wireguardSupported() {
		missing = append(missing, "the WireGuard kernel module")
	}
	if len(missing) > 0 {
		return check("network_tools", ipc.DoctorFail, "Missing "+strings.Join(missing, ", "),
			"Install wireguard-tools, iproute2, and nftables, and use a kernel with WireGuard", string(ipc.CommandSetupRequired))
	}
	return check("network_tools", ipc.DoctorPass, "wg, ip, and nft are installed and the kernel provides WireGuard", "", "")
}

// wireguardSupported matches the network package: loaded, built in, or installed for the running kernel
func (c *Controller) wireguardSupported() bool {
	if _, err := c.exec.ReadFile("/sys/module/wireguard/version"); err == nil {
		return true
	}
	release, err := c.exec.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return false
	}
	dir := filepath.Join("/lib/modules", strings.TrimSpace(string(release)))
	for _, name := range []string{"modules.builtin", "modules.dep"} {
		if data, err := c.exec.ReadFile(filepath.Join(dir, name)); err == nil && bytes.Contains(data, []byte("/wireguard.ko")) {
			return true
		}
	}
	return false
}

// diagnosticMode is the active mode, else the account's selected mode, else the saved intent's. Mesh is the default
func (c *Controller) diagnosticMode() ipc.Mode {
	intent := c.currentIntent()
	c.mu.Lock()
	defer c.mu.Unlock()
	switch {
	case c.obs.ActiveMode != "":
		return ipc.Mode(c.obs.ActiveMode)
	case c.user != "" && c.selectedMode != nil:
		return *c.selectedMode
	case intent.Mode != "":
		return intent.Mode
	}
	return ipc.ModeMesh
}

// doctorProfile lets Preflight read the resolver policy a Full start needs. Only its resolver findings are used
func doctorProfile() network.Profile {
	return network.Profile{
		ID: "doctor", Mode: network.ModeFull, Addresses: []netip.Prefix{netip.MustParsePrefix("10.0.0.2/32"), netip.MustParsePrefix("fd42:42:42::2/128")},
		DNS: []netip.Addr{netip.MustParseAddr("10.0.0.1")}, PeerPublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		AllowedIPs:   []netip.Prefix{netip.MustParsePrefix("0.0.0.0/0"), netip.MustParsePrefix("::/0")},
		EndpointHost: "doctor.invalid", EndpointPort: 51820,
		SetConf: func(netip.AddrPort, uint32) ([]byte, error) { return nil, errors.New("doctor profile") },
	}
}

func (c *Controller) resolverConflicts(ctx context.Context) (*network.PreflightError, error) {
	err := c.net.Preflight(ctx, doctorProfile())
	var preflight *network.PreflightError
	if errors.As(err, &preflight) {
		return preflight, nil
	}
	return nil, err
}

func (c *Controller) dnsPolicyCheck(ctx context.Context) *ipc.DoctorCheck {
	const name = "dns_policy"
	mesh := c.diagnosticMode() == ipc.ModeMesh
	c.mu.Lock()
	selectedFull := c.user != "" && c.selectedMode != nil && *c.selectedMode == ipc.ModeFull
	c.mu.Unlock()
	if mesh && !selectedFull {
		return check(name, ipc.DoctorPass, "Mesh mode leaves host DNS unchanged", "", "")
	}
	fullCheck := func(status ipc.DoctorStatus, evidence, suggestion, failureCode string) *ipc.DoctorCheck {
		if mesh {
			if status == ipc.DoctorFail {
				status = ipc.DoctorWarning
			}
			evidence = "Mesh remains connected. Selected Full: " + evidence
		}
		return check(name, status, evidence, suggestion, failureCode)
	}
	if c.currentIntent().Suppression == store.SuppressResolverFailure {
		return fullCheck(ipc.DoctorFail, "Another resolver change took Full mode DNS away from the VPN, so the daemon took the tunnel down",
			"Restore systemd-resolved as the only resolver for this host, then run: cloudgateway up", string(ipc.CommandVPNFailed))
	}
	conflicts, err := c.resolverConflicts(ctx)
	if err != nil {
		return fullCheck(ipc.DoctorUnknown, "The resolver policy could not be read", "", "")
	}
	setup := string(ipc.CommandSetupRequired)
	if conflicts != nil {
		for _, conflict := range conflicts.Conflicts {
			switch conflict.Kind {
			case network.ConflictMissingTools:
				if slices.Contains(conflict.Names, network.ToolResolvectl) || slices.Contains(conflict.Names, network.ToolBusctl) {
					return fullCheck(ipc.DoctorFail, "Full mode needs resolvectl and busctl from systemd",
						"Install systemd-resolved, or switch to Mesh: cloudgateway mode mesh", setup)
				}
				return fullCheck(ipc.DoctorUnknown, "Network tools are missing, so the resolver policy was not checked", "", "")
			case network.ConflictResolverInactive:
				return fullCheck(ipc.DoctorFail, "systemd-resolved is not active, so Full mode cannot carry VPN DNS",
					"Enable systemd-resolved, or switch to Mesh: cloudgateway mode mesh", setup)
			case network.ConflictResolverStub:
				return fullCheck(ipc.DoctorFail, "/etc/resolv.conf does not use the systemd-resolved stub",
					"Point /etc/resolv.conf at /run/systemd/resolve/stub-resolv.conf, or switch to Mesh: cloudgateway mode mesh", setup)
			case network.ConflictResolverDomains:
				return fullCheck(ipc.DoctorFail, "Another link has DNS search or routing domains that Full mode cannot override",
					"Remove the routing domains from the other link, or switch to Mesh: cloudgateway mode mesh", setup)
			}
		}
	}
	return fullCheck(ipc.DoctorPass, "systemd-resolved can carry Full mode VPN DNS", "", "")
}

func (c *Controller) resolverCheck(ctx context.Context) *ipc.DoctorCheck {
	const name = "resolver"
	const suggestion = "Full mode needs systemd-resolved as the host resolver. Mesh works without it"
	conflicts, err := c.resolverConflicts(ctx)
	if err != nil {
		return check(name, ipc.DoctorUnknown, "The resolver could not be read", "", "")
	}
	if conflicts != nil {
		for _, conflict := range conflicts.Conflicts {
			switch conflict.Kind {
			case network.ConflictMissingTools:
				return check(name, ipc.DoctorWarning, "resolvectl, busctl, or network tools are missing", suggestion, "")
			case network.ConflictResolverInactive:
				return check(name, ipc.DoctorWarning, "systemd-resolved is not active", suggestion, "")
			case network.ConflictResolverStub:
				return check(name, ipc.DoctorWarning, "/etc/resolv.conf does not use the systemd-resolved stub", suggestion, "")
			}
		}
	}
	upstream, err := c.upstreamServers(ctx)
	switch {
	case err != nil:
		return check(name, ipc.DoctorUnknown, "systemd-resolved is active, but its DNS servers could not be read", "", "")
	case upstream == 0:
		return check(name, ipc.DoctorWarning, "systemd-resolved has no upstream DNS servers outside the VPN", suggestion, "")
	}
	return check(name, ipc.DoctorPass, "systemd-resolved is active behind its stub with upstream DNS servers", "", "")
}

// upstreamServers counts resolved's DNS servers that do not belong to the VPN link
func (c *Controller) upstreamServers(ctx context.Context) (int, error) {
	out, err := c.exec.Run(ctx, network.ToolBusctl, []string{"--json=short", "get-property", "org.freedesktop.resolve1",
		"/org/freedesktop/resolve1", "org.freedesktop.resolve1.Manager", "DNS"}, nil)
	if err != nil {
		return 0, err
	}
	var reply struct {
		Data [][3]json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(out, &reply); err != nil {
		return 0, err
	}
	own := -1
	if links, err := c.exec.Run(ctx, network.ToolIP, []string{"-j", "-d", "-N", "address", "show"}, nil); err == nil {
		var parsed []struct {
			Index int    `json:"ifindex"`
			Name  string `json:"ifname"`
		}
		if json.Unmarshal(links, &parsed) == nil {
			for _, link := range parsed {
				if link.Name == network.InterfaceName {
					own = link.Index
				}
			}
		}
	}
	count := 0
	for _, entry := range reply.Data {
		var index int
		if json.Unmarshal(entry[0], &index) == nil && index != own {
			count++
		}
	}
	return count, nil
}

func (c *Controller) credentialsCheck() *ipc.DoctorCheck {
	const name = "credentials"
	_, err := c.store.LoadCredentials()
	switch {
	case err == nil:
		return check(name, ipc.DoctorPass, "Saved credentials are readable. Doctor does not restore or exchange them", "", "")
	case errors.Is(err, store.ErrMissing):
		return check(name, ipc.DoctorWarning, "No saved credentials", "Run: cloudgateway auth login", "")
	}
	return check(name, ipc.DoctorFail, "Saved credentials are unreadable", "Run: cloudgateway auth login",
		string(ipc.CommandCredentialsUnavailable))
}

func (c *Controller) accessCheck() *ipc.DoctorCheck {
	const name = "access"
	c.mu.Lock()
	access, retained := c.accessLocked(), c.creds != nil
	c.mu.Unlock()
	evidence := "Existing access evidence: " + string(access) + ". Doctor does not verify the account again"
	switch {
	case access == ipc.AccessOnline || access == ipc.AccessOffline:
		return check(name, ipc.DoctorPass, evidence, "", "")
	case access == ipc.AccessDenied:
		return check(name, ipc.DoctorFail, evidence, "Sign in again after access is restored", string(ipc.CommandAccessDenied))
	case !retained:
		return check(name, ipc.DoctorWarning, "Not signed in", "Run: cloudgateway auth login", "")
	}
	return check(name, ipc.DoctorUnknown, evidence, "", "")
}

// networkPathCheck looks for a main table default route in either family
func (c *Controller) networkPathCheck(ctx context.Context) *ipc.DoctorCheck {
	const name = "network_path"
	read := false
	for _, family := range []string{"-4", "-6"} {
		out, err := c.exec.Run(ctx, network.ToolIP, []string{"-j", "-N", family, "route", "show", "table", "all"}, nil)
		if err != nil {
			continue
		}
		var routes []struct {
			Dst   string          `json:"dst"`
			Table json.RawMessage `json:"table"`
			Type  string          `json:"type"`
		}
		if json.Unmarshal(out, &routes) != nil {
			continue
		}
		read = true
		for _, route := range routes {
			table := strings.Trim(string(route.Table), `"`)
			if route.Dst == "default" && (table == "" || table == "main" || table == "254") && (route.Type == "" || route.Type == "unicast") {
				return check(name, ipc.DoctorPass, "The host has a default route", "", "")
			}
		}
	}
	if !read {
		return check(name, ipc.DoctorUnknown, "Routes could not be read", "", "")
	}
	return check(name, ipc.DoctorFail, "The host has no default route", "Check this machine's network connection", "")
}

func (c *Controller) serverCheck(ctx context.Context) *ipc.DoctorCheck {
	const name = "server"
	if c.observe(ctx).State != network.StateConnected {
		return check(name, ipc.DoctorPass, "No tunnel is connected", "", "")
	}
	responding, err := c.net.ServerResponding(ctx)
	switch {
	case err != nil:
		return check(name, ipc.DoctorUnknown, "The connected server could not be checked", "", "")
	case !responding:
		return check(name, ipc.DoctorWarning, "The connected server is not responding through the tunnel", refreshSuggestion, "")
	}
	return check(name, ipc.DoctorPass, "The connected server responds through the tunnel", "", "")
}

// serviceCheck reads the regional health endpoint of the active or selected client's region
func (c *Controller) serviceCheck(ctx context.Context) *ipc.DoctorCheck {
	const name = "service"
	intent := c.currentIntent()
	c.mu.Lock()
	identifier := c.obs.ProfileID
	if identifier == "" && intent.Phase == store.PhaseRunning {
		identifier = intent.ProfileID
	}
	if identifier == "" && c.user != "" {
		identifier = c.selected
	}
	c.mu.Unlock()
	parts := strings.Split(identifier, "/")
	if !store.ValidIdentifier(identifier) || !validRegion(parts[1]) {
		return check(name, ipc.DoctorUnknown, "No known regional API is available for an optional health check", "", "")
	}
	region := parts[1]
	status, body, err := c.httpGet(ctx, "https://"+region+"."+buildinfo.Origin+"/api/health")
	var health struct {
		RegionID string `json:"regionId"`
		Status   string `json:"status"`
	}
	if err != nil || status != 200 || json.Unmarshal(body, &health) != nil || health.RegionID != region || health.Status != "ok" {
		return check(name, ipc.DoctorWarning, "The regional API did not return a matching healthy response", "", "")
	}
	return check(name, ipc.DoctorPass, "The known regional API reports healthy with matching region identity", "", "")
}

func validRegion(region string) bool {
	return region != "" && len(region) <= 63 && !strings.ContainsFunc(region, func(r rune) bool {
		return (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-'
	})
}
