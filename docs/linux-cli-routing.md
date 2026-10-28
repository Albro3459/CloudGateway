# Linux routing modes

Linux defaults to **Mesh**. Use it when a machine needs to reach CloudGateway
peers while keeping its normal internet connection and DNS. **Full mode is
experimental on cloud VMs** and needs compatible host routing and DNS settings.
The [Linux guide](../Frontend/Linux/README.md) covers installation and commands.

## Mesh vs Full

| Behavior | Mesh, the default | Full, experimental |
| --- | --- | --- |
| CloudGateway peers | Through the VPN | Through the VPN |
| New outbound internet connections | Host's normal exit | Selected regional exit, subject to the exceptions below |
| System DNS | Host's existing resolver | Regional VPN DNS through systemd-resolved |
| Private and local networks | Existing host routes | Preserved outside the tunnel, except CloudGateway mesh and VPN DNS destinations |
| DHCP/DNS changes normally needed | None | Provider search or routing domains may need adjustment |
| Best fit | Cloud servers, remote access, peer services | A host that also needs regional internet egress |

Mesh routes `10.0.0.0/16` and `fd42:42:42::/48`. A more-specific existing local
route still wins. Both modes use the same account-scoped peer permissions;
neither opens host firewall ports or changes which addresses a service binds to.

## Select a mode

```sh
cloudgateway mode status
cloudgateway mode mesh
cloudgateway mode full
cloudgateway status
cloudgateway doctor
```

The preference is saved per account on this machine. Changing it while
disconnected applies on the next `up`; changing it while connected switches the
same client. Saved choices survive upgrades. macOS and iOS keep their own defaults.

Check both **selected** and **active** mode. If Full fails its DNS preflight
while Mesh is running, Mesh stays connected but Full remains selected. Doctor
reports that mismatch. Run `cloudgateway mode mesh` to save Mesh again, or fix
the host and retry Full. A saved preference alone does not prove Full is active.

## Full on a cloud VM

Start in Mesh and keep provider console access available while changing host
network settings. Make changes inside the client VM first; changing a shared
VCN/VPC DHCP option set can affect other machines. CloudGateway does not edit
the VM's DHCP, Netplan, or provider configuration for you.

### Inspect the host

```sh
cloudgateway doctor
ip route show default
resolvectl dns
resolvectl domain
readlink /etc/resolv.conf
```

Full requires systemd-resolved running as the system resolver, with
`/etc/resolv.conf` pointing to its stub file at
`/run/systemd/resolve/stub-resolv.conf`. It also needs a working physical
network and upstream DNS before connecting, including for resolving the VPN
server. Mesh does not require systemd-resolved.

Full refuses search or routing domains on other DNS-enabled links or the global
resolver scope. A provider domain, a corporate split-DNS domain, or another
link's `~.` can divert queries away from the VPN. The presence of physical-link
DNS servers alone is allowed. Inspect every link, especially on multi-NIC VMs.
Do not disable DHCP or remove the physical gateway/DNS servers to bypass this
check: the VM still needs them outside the VPN and to recover from a failed start.

If private cloud service names depend on a search domain or provider-only DNS,
keep Mesh unless you have arranged a compatible naming/resolver setup. Full
does not offer simultaneous provider split DNS and exclusive VPN system DNS.

### Temporary OCI test

OCI supplied a DHCP search domain on both tested Ubuntu 24.04 architectures.
The following change allowed Full in those tests. Replace `ens3` with the
physical interface from the default route, and record its existing domains
before clearing them:

```sh
resolvectl domain ens3
sudo resolvectl domain ens3 ""
cloudgateway mode full
cloudgateway status
cloudgateway doctor
```

An empty argument clears that link's domain list; see the
[resolvectl reference](https://www.freedesktop.org/software/systemd/man/249/resolvectl.html).
This is a runtime test, not persistent setup. DHCP renewal, a network-manager
restart, or reboot may restore the domains. If that happens while Full is
running and its DNS policy cannot be repaired, the daemon disconnects and
restores normal host routing; it does not silently continue as healthy Full.

To return to Mesh, run `cloudgateway mode mesh`, then restore the exact domain
list you recorded with `sudo resolvectl domain ens3 <original-domains>`. Keep
search domains and `~` routing domains exactly as they were. The VM results
used this temporary adjustment; persistent provider configuration was not tested.

### Persistent Ubuntu Netplan setup

For a networkd-managed Ubuntu VM, change the existing interface definition to
ignore DHCP-provided domains. Preserve its interface matching, addresses,
routes, DNS servers, MTU, and other DHCP overrides. Back up the current Netplan
files before editing. This is a fragment to adapt, not a replacement cloud image
configuration:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      dhcp4: true
      dhcp4-overrides:
        use-domains: false
```

If DHCPv6 is enabled, use matching keys and values in `dhcp6-overrides` as well.
The networkd backend requires both override maps to match when both DHCP
families are enabled. Leave DHCP DNS enabled so the VM can resolve names before
connecting. These settings are documented in the
[Netplan DHCP reference](https://netplan.readthedocs.io/en/stable/netplan-yaml/#dhcp-overrides).

Remove any conflicting explicit search/routing domains only after confirming
they are unnecessary. If domains come from IPv6 router advertisements, another
NIC, global resolved settings, or NetworkManager, changing DHCPv4 alone will not
fix them. Configure their actual source, or stay in Mesh. Cloud-init or provider
automation may regenerate network settings; make the change in that source of
truth and check persistence after reboot and DHCP renewal.

Disconnect first and apply host changes from the provider console:

```sh
cloudgateway down
sudo netplan generate
sudo netplan try --timeout 120
```

Confirm the trial only after checking SSH, default routing, and DNS. Keep console
access even with `netplan try`: its documentation notes cases where rollback
must be verified. See the [Netplan trial reference](https://netplan.readthedocs.io/en/stable/netplan-try/).
Then reconnect in Full and check doctor again. This recommendation follows
Netplan's configuration model; only the temporary OCI workaround above has
CloudGateway VM test evidence.

### Verify and recover

Verify a newly opened SSH connection, necessary VPC services, metadata and time
sync, ordinary HTTPS over both IP families, and the expected regional public
exit. In Full, `resolvectl status cloudgateway` should show VPN DNS servers and
the `~.` routing domain. Doctor should report the active mode and DNS policy as
healthy. Repeat the checks after DHCP renewal, reboot, or network-manager changes.

For recovery from the enrolled user or root console:

```sh
cloudgateway down
cloudgateway mode mesh
```

Restore host networking separately if you changed it. `down` works without a
signed-in account; sign back in before changing a saved mode. Logout does not
disconnect an active VPN.

## Routing limits

* Full preserves private, shared, link-local, and more-specific host routes so
  cloud management traffic can keep using the physical network. CloudGateway
  mesh and VPN DNS destinations take their own tunnel routes. An overlapping
  local network can prevent a mesh peer from being reachable.
* Programs bound to a physical source address bypass Full. Connections opened
  before Full starts may retain that source and remain outside the tunnel.
* Full is not a kill switch. A failed connection or DNS-policy teardown can
  restore ordinary internet access through the physical network.
* Docker-published ports, libvirt forwarding, and UDP services without a chosen
  source address can reply through the tunnel in Full. Multi-NIC policy routing
  and globally addressed VPC IPv6 networks need separate validation.
* Docker container DNS can bypass resolved's per-link policy. Full's system DNS
  behavior applies to host applications using the supported system resolver;
  it is not a container DNS isolation guarantee.

## Tested scope

Ubuntu 24.04 LTS on ARM64 and AMD64 passed sign-in, same/cross-region IPv4 and
IPv6 peer reachability, Mesh internet behavior, and Full regional egress/DNS
after the OCI adjustment. AMD64 also passed Mesh reboot resume and explicit
`down` persistence. See [versions and sanitized results](linux-cli-vm-results.md).

Other distributions, persistent Full-mode reboot setup, connected upgrades
between releases, cross-account denial on live VMs, deliberate daemon crashes,
and the broader network failure cases remain unverified. The
[design's validation notes](linux-cli-research.md#validation-and-known-limits)
retain those scenarios without expanding the Ubuntu 24.04 release scope.
