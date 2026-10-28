# Linux CLI VM results

Current Linux policy is Mesh-first, unlike macOS and iOS. Full mode is
experimental and may require cloud-provider DHCP/DNS configuration. This policy
starts with v0.0.3; the v0.0.1/v0.0.2 runs below used the old Full
default. Their saved mode choices are not changed by an update.

Network addresses and provider-specific domain names are omitted. Role labels
preserve the routing evidence without identifying individual hosts.
Results also omit account, client, and infrastructure identifiers, approval
codes, and credentials. Local test artifacts retain sanitized check summaries.

## 2026-10-27: v0.0.3, Ubuntu 24.04 amd64

Result: native login, the new Mesh default, inventory, client creation,
Chicago/San Jose Mesh and Full connectivity, and reboot recovery passed. Full
required the same temporary DNS search-domain adjustment as the arm64 run.

### Environment

* Release: [linux-v0.0.3](https://github.com/Albro3459/CloudGateway/releases/tag/linux-v0.0.3)
* Source commit: `10d4cbe83a322fb85ad98c69d06104f127297f7c`
* OCI image: `Canonical-Ubuntu-24.04-2026.09.18-0`
* Architecture: `x86_64`, kernel `6.17.0-1020-oracle`
* OS: Ubuntu 24.04.5 LTS
* Region: Chicago, availability domain 1
* Shape: paid `VM.Standard.E4.Flex`, 1 OCPU and 1 GB RAM

The Always Free `E2.1.Micro` shape was absent from all three Chicago availability
domains. Its initial launch failed without creating a VM. The test Terraform
setup now accepts an explicit paid E4 fallback and keeps E2 as its amd64 default.
Both installed executables matched the published amd64 archive's SHA-256 hashes.

### Connectivity and DNS

The Mac stayed connected to its existing Chicago Mesh client. The VM used
separate temporary Chicago and San Jose clients. Each ping case sent three
requests to the Mac peer in each address family.

| VM client | Mode | Mac IPv4 ping | Mac IPv6 ping | Public IPv4 |
| --- | --- | --- | --- | --- |
| Chicago | Mesh | 3/3, 0% loss | 3/3, 0% loss | VM underlay |
| Chicago | Full | 3/3, 0% loss | 3/3, 0% loss | Chicago exit |
| San Jose | Mesh | 3/3, 0% loss | 3/3, 0% loss | VM underlay |
| San Jose | Full | 3/3, 0% loss | 3/3, 0% loss | San Jose exit |

The fresh account selected Mesh after login and connected without a mode change.
With stock OCI DHCP DNS, switching to Full returned `setup_required`, preserved
the connected Mesh tunnel, and left doctor reporting a Full-readiness warning.
Human output included the experimental-mode and DHCP guidance on stderr.

Temporarily clearing the physical interface's DNS search domain enabled Full.
Both regions then provided IPv6 HTTPS egress, tunnel DNS servers, and the `~.`
DNS routing domain. All 13 doctor checks passed in each region. Mesh left tunnel
DNS unset. Stock search domains were restored after Full checks. No shared VCN
DHCP or subnet settings were changed.

### Runtime

The unenrolled `ubuntu` user was denied daemon access. The state directory was
mode `0700` and the operator socket was mode `0600`. Restarting the daemon in
Chicago Full adopted the existing interface without replacing it. The installed
release's no-op `update` completed with the tunnel connected. This does not
validate an upgrade between different releases.

A connected reboot restored authentication and resumed the same San Jose Mesh
client. Both address families still reached the Mac, and public IPv4 stayed on
the VM underlay. After explicit `down`, another reboot restored authentication
but kept the tunnel disconnected through the subsequent 20-second observation.

Ubuntu 26.04, connected release upgrades, Full-mode reboot with persistent DNS
setup, cross-account denial, and failure-injection cases remain untested.

### Cleanup

Both temporary clients were removed online. The original inventory and the
Mac's connected Mesh client were preserved. Signed-out `down` succeeded, while
signed-out `up` required login. The owned interface, both-family policy rules
and routes, and nftables table were absent after disconnect. Uninstall with
`--purge` removed the CLI, releases, state, and systemd unit.

Terraform destroyed the VM and its boot volume. Follow-up OCI reads confirmed
the VM was terminated, no active test boot volume remained, and existing
instances, boot volumes, subnet configuration, and security rules were unchanged.
The test state has no managed resources remaining.

A separate follow-up audit covered all three Chicago availability domains and
all accessible compartments. It found one running VPN server and one 50 GB
boot volume attached to that server, with no other nonterminated VMs or boot
volumes.

## 2026-10-27: v0.0.2, Ubuntu 24.04 arm64

Result: native login, inventory, client creation, Mesh, Full, daemon adoption,
and cleanup checks passed on the 1 OCPU / 1 GB Chicago VM. This is one platform
scenario, not completion of the Ubuntu/architecture acceptance matrix.

Release: [linux-v0.0.2](https://github.com/Albro3459/CloudGateway/releases/tag/linux-v0.0.2).
Source, toolchain, OCI image, OS, and kernel match the v0.0.1 run below. This
build uses the existing native Firebase API key. No Firebase restrictions were changed.

### Connectivity

The Mac stayed connected to its existing Chicago client in Mesh mode. The VM
used separate temporary Chicago and San Jose clients in sequence. Each ping
case sent three requests to the Mac peer's IPv4 and IPv6 tunnel addresses.

| VM client | Mode | Mac IPv4 ping | Mac IPv6 ping | Public IPv4 |
| --- | --- | --- | --- | --- |
| Chicago | Mesh | 3/3, 0% loss | 3/3, 0% loss | VM underlay |
| Chicago | Full | 3/3, 0% loss | 3/3, 0% loss | Chicago exit |
| San Jose | Mesh | 3/3, 0% loss | 3/3, 0% loss | VM underlay |
| San Jose | Full | 3/3, 0% loss | 3/3, 0% loss | San Jose exit |

`curl -4 --fail --silent --show-error --max-time 20 https://ifconfig.me/ip`
confirmed the disconnected VM address and both Full-mode exit addresses.
Mesh retained the physical IPv4 address, verified with ipify. Both Full-mode
clients also completed an IPv6 HTTPS public-IP check through their regional
server. New public-IP SSH sessions worked while Full was active in both regions.

### DNS prerequisite and diagnostics

With stock OCI DHCP settings, `mode full` refused with `setup_required` and
kept the existing Mesh tunnel connected. The physical link's
provider-assigned DNS search domain was then cleared temporarily with
`resolvectl domain enp0s6 ""` on the test VM. Full worked after this adjustment.
No VCN DHCP or subnet settings were changed.

In Full, resolved showed the selected region's IPv4/IPv6 VPN DNS servers and
the `~.` routing domain on the CloudGateway link. Mesh left the physical DNS
servers in use and did not configure tunnel DNS. The search domain was restored
before teardown. After the Full-mode adjustment, all 13 doctor checks passed.

### Lifecycle and host firewall

* Restarting the daemon while connected in Chicago Full adopted the existing
  tunnel. The first status showed auth restoring while the tunnel stayed Full
  and connected. Subsequent authenticated commands succeeded.
* Switching the connected client from Chicago to San Jose worked without a new login.
* A separate Mac-to-VM TCP probe passed IPv6 and was refused for IPv4. The
  stock IPv4 host firewall accepts ICMP and SSH, then rejects other new inbound
  traffic. The refusal is consistent with that policy. No exception was added.
* `down` restored the direct IPv4 exit. Both test clients were removed online,
  and a refreshed inventory confirmed their UUIDs were absent.
* Logout and uninstall with `--purge` removed credentials, daemon state, CLI,
  releases, and the systemd unit.

### Teardown

The test VM and boot volume were destroyed after testing. Existing running
instances, boot volumes, and subnet rules were unchanged. The Mac remained
connected in Mesh mode. Reboot resume, connected release upgrades, other OS/CPU
targets, cross-account denial, and failure-injection cases remain untested.

## 2026-10-27: v0.0.1, Ubuntu 24.04 arm64

Result: installation and local daemon checks passed. Browser-approved login
failed before authenticated inventory or VPN testing.

### Environment

* Release: [linux-v0.0.1](https://github.com/Albro3459/CloudGateway/releases/tag/linux-v0.0.1)
* Source commit: `7e54eda709f5349353a05c9986ed012650dd8aca`
* Build toolchain: `go1.27.3`
* OCI region: `us-chicago-1`, availability domain 1
* Shape: `VM.Standard.A1.Flex`, confirmed 1 OCPU and 1 GB RAM
* Image: `Canonical-Ubuntu-24.04-aarch64-2026.09.18-0`
* OS: Ubuntu 24.04.5 LTS, `aarch64`, kernel `6.17.0-1020-oracle`
* Underlay: IPv4, non-overlapping private subnet, OCI jumbo-frame NIC

### Passed

* Cloud-init downloaded the published installer and completed without errors.
* The installer installed missing WireGuard tools and the arm64 release.
* `cloudgateway version --json` reported version/build `0.0.1`.
* The root systemd daemon started and answered the enrolled operator's handshake.
* Doctor confirmed the installation, daemon, kernel WireGuard, network tools,
  systemd-resolved stub, default route, site DNS, and API HTTPS readiness.
* The daemon rejected requests from the unenrolled `ubuntu` user.
* The state directory was mode `0700` and the operator socket was mode `0600`.
* Device login created a challenge and the user approved it in the browser.
* Signed-out `down` completed with the tunnel disconnected.
* Signed-out `up` refused with `sign_in_required`.
* Uninstall with `--purge` removed the CLI link, releases, state, and systemd unit.

### Login failure

The release used the web app's Firebase API key. Its HTTP-referrer restriction
rejects the CLI's headless Auth request. After browser approval, the CLI returned
`credentials_unavailable` and remained signed out.

A diagnostic Auth request with a deliberately invalid token returned HTTP 403,
`API_KEY_HTTP_REFERRER_BLOCKED`, and `Requests from referer <empty> are blocked.`
No real token or credential was printed.

The same diagnostic using the existing macOS client's public API key reached
token validation and returned HTTP 400 `INVALID_CUSTOM_TOKEN`. That verifies
the key is accepted for this headless request, not that a complete login works.
The ignored local Linux release configuration now uses that native key. The
published v0.0.1 assets and Firebase key restrictions were not changed.

This required a new build with a native-compatible key. The v0.0.2 results
above cover the login and connectivity retry. See
[Firebase API key guidance](https://firebase.google.com/docs/projects/api-keys).

### Full-mode prerequisite

OCI DHCP supplied a provider-assigned DNS search domain on the physical interface.
Doctor correctly reported that another link's DNS domains block Full mode.
This matches the known resolver limitation in the research document. The VM's
DNS configuration was not changed, and Full-mode routing was not exercised.

### Teardown

No VPN client was created because login failed. Terraform terminated the test
VM with `preserve_boot_volume = false`. Follow-up OCI reads confirmed the VM
was terminated and its boot volume was absent from active volumes. The test
Terraform state has no managed resources remaining.

Existing running instances, boot volumes, and subnet ingress/egress rules were
unchanged. The Mac client remained connected in Mesh mode.
