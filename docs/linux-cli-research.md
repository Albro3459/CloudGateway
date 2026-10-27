# Linux CLI research

Research date: 2026-10-26. Reference implementation: `32dae6c` on `main`.

This is a proposed implementation design. There is no Linux client, installer,
release, or completed Linux VM validation yet. Source inspection establishes
backend capability, not the state of deployed servers.

## Scope and original decisions

This document supersedes the earlier cross-distro Linux CLI proposal, including
the final user corrections from that discussion. The current macOS CLI is the
public compatibility baseline. Linux emulates its interface, not its process
architecture. See the [parity contract](linux-cli-parity.md) and
[implementation checkpoints](../TODO/linux-cli.md).

| Earlier proposal | Updated decision |
| --- | --- |
| Direct Firebase REST reads | Keep. Use existing regional APIs for mutations |
| Named client creation | Keep, using macOS `add <region> <name>` |
| Required `up --mode` | Superseded by current `mode full\|mesh`, saved per-account preference, Full default |
| Number from the last displayed list | Superseded by current region-local indices from settled inventory |
| `login`, `regions`, `--autostart` examples | Use the implemented macOS command surface, with no added public commands/flags |
| Daemon from v1 | Keep, as one root daemon. Accepted work must survive CLI/SSH detachment |
| Bundle `wg` or `wg-quick` | Wrap `wg`; own routes and DNS. Start with distro `wireguard-tools` |
| Ubuntu first, few OS flags | Keep. Detect capabilities, with no distro flags in normal commands |
| Shell installer, no CloudGateway package repository | Keep. Verify release assets before privileged installation |
| Future P2P | Keep the daemon extensible, without adding P2P to this release |

Initial release targets are Ubuntu Server 24.04 and 26.04 LTS on amd64 and arm64,
subject to the VM gates below. Both are current LTS lines in the
[Ubuntu release schedule](https://ubuntu.com/about/release-cycle).
Debian, Arch/Omarchy, Amazon Linux, and Oracle Linux remain unverified targets.
Do not publish a percentage compatibility claim or say Ubuntu is tested before
running the matrix. Linux containers, WSL, non-systemd hosts, and user-space
WireGuard fallbacks are outside the initial target.

## Implementation choice

Recommend Go under `Frontend/Linux/`, with a thin `cloudgateway` executable and
one root background daemon.
Use standard-library HTTP, JSON, cryptographic randomness, hashing, and local IPC.
No generic REST framework is needed. Go's
[`net/http`](https://pkg.go.dev/net/http) supplies HTTPS and transport control.
QR encoding and terminal support may need small pinned dependencies. Choose
those against the terminal parity fixtures rather than promising zero dependencies.

Swift remains possible. The official
[Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
supports distribution without installing a Swift runtime separately. However,
the current complete packages import Apple Network, NetworkExtension, Security,
Combine, Darwin/XPC, and the Firebase Apple SDK. They cannot be reused unchanged.
Extracting a portable contract core would require a separate refactor and Linux
adapters. Go avoids that refactor but duplicates policy logic. Shared contract
fixtures are therefore an implementation requirement.

### Process and local authority

* `cloudgateway`: parser, rendering, terminal interaction, and IPC only. Help and
  version work locally without the daemon, credentials, or network access.
* `cloudgatewayd`: one root systemd service. Owns device login, Firebase
  tokens/refresh, inventory/cache, account generations, selections, modes,
  operation reservations/results, cloud mutations, the managed kernel interface,
  retained tunnel secret records, route/rule/mark allocation, its nftables table,
  resolver integration, observed network state, and an interrupted-change
  journal. Runs independently of login sessions.

macOS splits this work because NetworkExtension runs the tunnel in a separate
OS-managed process. Linux has no such requirement. A second Linux service would
need its own socket, intent protocol, and restart handshake, and the privileged
side would still parse downloaded configs. tailscaled and NetBird also run one
root daemon. Keep the network code in its own Go package with a typed interface
and no HTTP or Firebase imports, so the boundary stays without a second process.

Linux interface and routing changes need
[`CAP_NET_ADMIN`](https://man7.org/linux/man-pages/man7/capabilities.7.html).
That capability alone does not grant resolver D-Bus or privileged file access.
Run as root and restrict the unit with systemd capability and filesystem
controls. Do not apply `PrivateNetwork` or a sandbox that hides the host network
it must configure. Exact unit settings need a spike on both supported Ubuntu
versions, rather than copying latest-systemd options.

Enroll one administrator-designated local operator UID during installation.
The daemon socket accepts that UID and root. Check filesystem socket permissions
and kernel [`SO_PEERCRED`](https://man7.org/linux/man-pages/man7/unix.7.html) on
every connection. Never trust a UID/account claim supplied in a request.
Cloud admin status does not confer local machine control. Root is the recovery
authority, not a second Firebase account. Other local users cannot inspect or
stop the operator's connection.

Bind account-bound requests to the enrolled UID, Firebase UID, and session
generation. Bare down requires local operator authority, with no account or
usable auth credentials. The network package accepts bounded typed operations
and opaque profile IDs, never arbitrary executable names, paths, shell snippets,
or routes. Use bounded length-framed local messages and explicit IPC versions.
Canonical profile identity stays `signedInUID/regionId/clientId`, including admin
views of another owner's client. Root-owned installation directories prevent an
ordinary user from replacing the daemon or its dependencies.

### Secrets and persisted state

Keep metadata caches separate from credentials and tunnel secrets. The daemon's
state directory is root-owned `0700`. Credentials and structured tunnel secret
records are separate, atomically replaced `0600` files. Do not persist downloaded config
documents in metadata, operation logs, journals, or diagnostic output. An
opaque reference identifies the retained secret record. Logout and client
removal keep secret records. A denial, role downgrade, or refresh that revokes
or rotates a config deletes its record, except the one the running tunnel uses.

This baseline is plaintext secret storage protected by OS permissions, not
Keychain-equivalent encrypted storage. It supports unattended VMs without a
desktop keyring. Full-disk encryption and backups remain host concerns.
[Systemd encrypted credentials](https://www.freedesktop.org/software/systemd/man/latest/systemd-creds.html)
can later protect stored blobs using a host key or TPM. A host key on the same
disk does not protect against theft of the entire disk, and rotating refresh
tokens still require a durable write path. Do not make TPM availability a v1
requirement.

Pass WireGuard configuration to `wg` through an inherited descriptor/pipe,
with no key bytes in argv or ordinary temporary files. Disable core dumps for
the daemon. Never print raw HTTP error bodies, tokens, keys, full configs,
`wg showconf`, or `wg show ... dump`. No VPN traffic, DNS-query, packet,
destination, or per-user connection-history logging is added.

## REST client and account lifecycle

Use the existing [API contract](api-contract.md), [device protocol](device-auth.md),
[Firestore schema](../Backend/Firebase/schema.ts), and
[rules](../Backend/Firebase/firestore.rules). Ship only public Firebase project
configuration, API key, database ID, and CloudGateway origins. No service account,
Admin SDK credentials, private Firebase secrets, or login proof ships in a binary.
[Firebase API keys identify the project](https://firebase.google.com/docs/projects/api-keys).
Verify native-client API restrictions against staging before release.

### Login, refresh, and logout

1. Generate a fresh 32-byte random login secret. Create a request with
   `POST https://api.<origin>/api/device/code`, sending its lowercase SHA-256
   digest and `deviceName: "CloudGateway for Linux"`. The approval page shows
   that name, matching macOS's `CloudGateway for macOS`. Keep the original
   secret in memory for that attempt only.
2. Display the returned approval URL and six-digit code promptly. Preserve
   leading zeroes and macOS QR/terminal/JSON behavior. Browser approval uses the
   existing site. The CLI does not automatically open a browser.
3. Poll `/api/device/token` with the request ID and unpadded base64url secret.
   Respect the returned interval, expiry, and `Retry-After`. Requests live for
   300 seconds and initial polling is five seconds. Lost redemption responses
   require a fresh attempt because the server consumes the request first.
4. Exchange `customToken` using
   [`accounts:signInWithCustomToken`](https://docs.cloud.google.com/identity-platform/docs/reference/rest/v1/accounts/signInWithCustomToken).
   Parse string `expiresIn`; do not require an undocumented `localId` field.
   Verify identity and role through authenticated `/api/auth/check-access`.
5. Commit refresh credentials atomically behind the current attempt/account
   generation. Use the
   [Secure Token refresh API](https://firebase.google.com/docs/reference/rest/auth#section-refresh-token),
   whose response uses snake-case field names. Serialize refreshes, check
   returned user/project continuity, and persist replacement tokens atomically.

Keep retained credentials, verified product access, and observed VPN state
independent. Definite invalid/revoked/disabled credentials require login again.
Transport failures and `AUTH_UNAVAILABLE` retain the session. Do not turn an
outage into a permission denial. Parse CloudGateway, Firebase Auth, and Firestore
error formats separately, then map them to the existing safe CLI errors.

Logout is local. It clears auth credentials, invalidates in-flight account work,
and hides inventory while retaining the running VPN, secret records, metadata
caches, and selection. It disables future automatic starts. Bare `down` remains
available to the enrolled operator while signed out. There is no current
per-device remote logout/revocation API.

### Firestore reads

Send a Firebase user ID token as bearer authentication so
[Firestore Security Rules apply](https://firebase.google.com/docs/firestore/use-rest-api).
Use `documents:runQuery` for enabled `Regions` and the `Instances` collection
group. Ordinary-user instance queries must filter `ownerUid == authenticatedUID`.
Only a verified admin may omit that filter. Rules are
[not post-query filters](https://firebase.google.com/docs/firestore/security/rules-query).

Fetch selected configs with a document GET at
`Regions/<regionId>/Instances/<clientId>`. Existing rules support these reads
and forbid direct instance mutations. Own `Users`/`UserRoles` GETs are available,
but ordinary users cannot list them or read role-limit documents. Capacity uses
the regional API, and create remains authoritative for user quota enforcement.

Decode the [typed Value format](https://firebase.google.com/docs/firestore/reference/rest/v1/Value)
explicitly, including string-valued integers, RFC3339 timestamps, nulls, maps,
arrays, and references. Validate path identity, owner, status, and enabled region
before a start. Initially read full config-bearing inventory, matching macOS.
Compute authorization hashes from canonical configs during the complete refresh,
then discard secret-bearing documents from presentation/metadata storage.
Metadata-only projection cannot renew cached config hashes or establish offline
eligibility. A later optimization must fetch every retained config needing
validation within the same snapshot before publishing renewed authorization.
Selected-config GETs alone cannot establish that unchanged-looking inventory
still authorizes the bytes in a retained secret record.

Match macOS: one unpaged region query and one unpaged client query, run
together. Inventory is small, so there is no paging, cursor, or transaction.
[`runQuery`](https://firebase.google.com/docs/firestore/reference/rest/v1/projects.databases.documents/runQuery)
streams every result in one response. Handle response entries without a
document. Replace the authorized cache only after both queries and a final
current access/role check succeed. Filter statuses locally to avoid new
composite indexes.

Mirror account-generation fences, role-downgrade invalidation, authorized config
hashes, and classified offline fallback from the macOS controller. Only a
transport failure with previous account authorization permits offline starts.
Denial, malformed replies, and incomplete reads do not grant offline access.
An old role-less cache requires fresh authorization. No new cache age TTL is
introduced as an accidental Linux policy difference.

The inventory stale threshold is 60 seconds. Port the scheduler from
[source](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacInventorySchedule.swift): active polling, idle backoff,
suspension, and explicit refresh have different rules. Do not turn the VM daemon
into an unbounded high-frequency Firestore poller. Close idle HTTP connections
after route changes so Firebase/control-plane traffic can use the new path.

### Cloud mutations and unknown outcomes

Use `https://<regionId>.<origin>/api/capacity`, `POST /api/clients`, and
`DELETE /api/clients/<clientId>`. Add sends `regionId` and `clientName`; delete
sends the captured owner `userId` and `regionId` in its JSON body. Do not request
account cleanup. Both already trigger the relevant regional policy work.
`/api/sync/refresh` queues ACL work and is not a client inventory refresh.

Creation has no backend idempotency key. Another POST can create another client.
Preserve macOS's conservative unknown-outcome behavior after uncertain dispatch,
including ordinary create HTTP failures whose effects are not proven. Actual
401/403 invalidates access. Do not automatically resend create, delete, or
single-use redemption, or add an idempotency header the backend does not support.
Timeouts stop observation, not accepted daemon work.

Removal requires fresh authorization and an exact inactive target. Evict local
eligibility durably before dispatch, preserve uncertain eviction across restart,
and never infer removal from a changed index. Verified deletion succeeds even
if local cleanup/inventory refresh needs a warning. Retained secret records stay
under the existing retention policy. A failed network observation or unknown
runtime state cannot prove that a target is inactive.

Use explicit HTTP deadlines, response-size limits, redirect rejection for
authenticated requests, and closed response bodies. Safe authenticated reads
may force one token refresh. Do not apply a generic retry middleware to writes.
Reliable exactly-once create retries would require a separate backend contract
change and are outside Linux parity work.

## WireGuard and network lifecycle

The [backend config generator](../Backend/API/src/wireguard.py) already supplies
IPv4 `/32`, IPv6 `/128`, both regional DNS addresses, full default AllowedIPs,
and a 25-second keepalive. The
[shared mode transform](../Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/CloudGatewayRoutingMode.swift)
defines Full as canonical config and Mesh as `10.0.0.0/16`, `fd42:42:42::/48`,
with no VPN DNS/search domains. Linux must apply that same transform without
rewriting the stored canonical config or rotating keys.

The server bootstrap contains IPv4/IPv6 forwarding, regional NAT/NAT66, and
tunnel DNS rules. Region reconciliation supplies remote mesh routes and the
account ACL enforces forwarded peer access. Actual public IPv6 egress also needs
working server upstream IPv6 and must be verified live. Inner IPv6 can travel
over an IPv4-only WireGuard endpoint. Linux mesh remains server-routed, with the
same cross-region membership and ACL prerequisites as Apple.
Preflight must reject a host that cannot install the required IPv6 tunnel state.
An IPv4-only physical connection is supported; silently omitting inner IPv6
while reporting full-mode success is not.

### Why wrap `wg` rather than `wg-quick`

[`wg`](https://git.zx2c4.com/wireguard-tools/plain/src/man/wg.8) configures
WireGuard peers/keys, while Linux tools configure links and routes. This lets the
daemon own resource identity, rollback, DNS, and observed state explicitly.
Invoke trusted absolute executables with fixed argument arrays, never a shell.

[`wg-quick`](https://git.zx2c4.com/wireguard-tools/plain/src/man/wg-quick.8)
also configures routing/DNS but executes user-configured hooks and expects
`resolvconf` for its DNS field. Its
[Linux cleanup](https://git.zx2c4.com/wireguard-tools/plain/src/wg-quick/linux.bash)
does not identify ownership of every policy rule it removes. A generated,
hook-free configuration could support a prototype, but it is not the preferred
production lifecycle for this daemon.

Reject hooks, `SaveConfig`, arbitrary table choices, unknown fields, malformed
keys/addresses, and unsupported peer layouts at the config boundary. Reconstruct
only supported fields. Never run a downloaded config as privileged shell input.
Use distro `wireguard-tools` initially. Bundling a pinned `wg` remains possible,
with license/source obligations, but does not supply the kernel driver,
`iproute2`, resolver service, CA certificates, or firewall integration.
The [official installation guide](https://www.wireguard.com/install/) covers
Ubuntu, Debian, and Arch. Direct netlink or
[`wgctrl-go`](https://github.com/WireGuard/wgctrl-go) can replace the adapter later,
but neither removes route/DNS lifecycle work.

### Full routing and VM access

Full means public internet traffic and DNS use the region. Browsers, package
managers, and other outbound connections exit from the regional server over
IPv4 and IPv6. Private, shared (`100.64.0.0/10`), and link-local destinations
stay on the VM's own network, so VPC peers, internal load balancers, metadata,
and LANs keep working, and SSH into the machine keeps working. The mesh ranges
and VPN DNS still use the tunnel. macOS only keeps the Mac's local subnets out of
the tunnel. A cloud VM often reaches its VPC through the default gateway, as on
GCE with a `/32` address or across AWS subnets, so Linux keeps all private
ranges out.

Use the `wg-quick` policy routing pattern for both address families. WireGuard's
[routing reference](https://www.wireguard.com/netns/) explains it.

* A dedicated route table holds the tunnel default route. A rule sends every
  packet without the tunnel's fwmark to that table. WireGuard marks its own
  encrypted packets, so they use the physical link.
* A higher-priority `lookup main suppress_prefixlength 0` rule keeps every
  more-specific main-table route outside the tunnel. That covers directly
  connected subnets, cloud static routes, and container bridges. Only the
  default route moves.
* Higher-priority `to <prefix> lookup main` rules keep `10.0.0.0/8`,
  `100.64.0.0/10`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`,
  `fc00::/7`, and `fe80::/10` outside the tunnel even when main only has a
  default route to them. Rules ahead of those send the mesh ranges, and any VPN
  DNS address inside a private range, to the tunnel table.
* A higher-priority `from <physical address> lookup main` rule for each physical
  address sends replies to inbound sessions out the physical link. SSH from any
  source keeps working without a management allowlist. The daemon updates these
  rules when DHCP changes an address.

An application that explicitly binds to the physical address also bypasses the
tunnel. Full-route claims disclose that and the local-route behavior.

Allocate one interface and dedicated route tables, rule priorities, and marks
for both address families. Record the allocation and reject collisions. Owned
resources use fixed identities, so the daemon can find and remove them without
the journal.

The implementation uses interface `cloudgateway` with alias `cloudgatewayd`,
created as `cloudgw-pending` and renamed once the alias is set, so a crash
never leaves an ambiguous link. Table and fwmark are `52820`, and rules and
routes carry routing protocol `206`. Rule priorities are `30200` for physical
source addresses, `30203` for the mesh ranges and VPN DNS, `30205` for private
and link-local destinations, `30210` for the suppress rule, and `30220` for the
tunnel rule. They stay clear of Tailscale's `5210`-`5270`. Source rules cover
addresses on links that are up, so a Kubernetes `kube-ipvs0` with one address
per service adds none. The daemon also refuses an endpoint inside the tunnel's
own routes, since its encrypted packets would loop. A journal must name a known resource set, and teardown
never matches protocol `0` or `2`, so a damaged journal can't remove kernel
rules. Rule, table, and mark collision checks apply only to Full, which is the
only mode that installs them.

Ubuntu Server manages its network with netplan and systemd-networkd. By default,
networkd [removes routing rules and routes](https://www.freedesktop.org/software/systemd/man/latest/networkd.conf.html)
it didn't configure, such as after `netplan apply` or a networkd restart. It
ignores links it doesn't manage, so tunnel interface routes are likely safe.
Policy rules are exposed. `wg-quick` doesn't handle this. If those rules vanish,
Full traffic quietly falls back to the underlay. The daemon watches its owned
rules and routes over netlink and reapplies any that disappear, reporting
`connecting` until they match again.

The backend config has no `MTU` line. Set the interface MTU to the smaller of
the route MTU toward the endpoint and 1500, minus 80. Ordinary links get 1420,
which matches macOS's physical MTU minus 80 on a 1500-byte network. Cloud NICs
often use jumbo frames, such as OCI's 9000-byte default, while their internet
gateways drop packets over 1500. The plain `wg-quick` calculation would produce
an 8920-byte tunnel there. A config `MTU` wins, as on macOS.

Preflight must inspect actual routes, local addresses, other VPNs, and resolver
paths. A cloud VPC overlapping `10.0.0.0/16` is a concrete blocker, including
local addresses or more-specific routes that capture regional DNS. Reject
known conflicts before mutation and report prefixes, rather than silently
choosing VPC or mesh ownership. Identical destination addresses require an
operator addressing decision. Do not change the fleet range in this ticket.
This is a known limitation for hosts whose own network uses `10.0.0.0/24` or
`10.0.1.0/24`, such as a default OCI VCN or a home router on 10.0.0.x.

The public CLI gains no Linux-only routing flags.

### Owned nftables table

`wg-quick` adds nftables rules beyond routes, and the daemon needs equivalents.
Own one `inet cloudgateway_client` table. Its name differs from the regional
servers' `inet cloudgateway` ACL table in the
[host bootstrap](../Infrastructure/OCI/host/bootstrap.sh), so a test install on
a server can't remove server policy. Like the server, create the table on up,
delete the whole table on down, and never edit other tables or flush global
rules. A drop verdict in any table is final, so this table can't weaken UFW or
other firewall rules.

* In both modes, drop packets addressed to the tunnel addresses that arrive on
  another interface, unless they come from the host itself. Linux accepts
  traffic for any local address on any interface. Without this rule, a neighbor
  on the same LAN or VPC can reach services bound to the mesh address and skip
  the server-side account ACL.
* In Full, copy the WireGuard UDP connection mark back onto incoming packets and
  set `net.ipv4.conf.all.src_valid_mark=1`. Without them, a host with strict
  `rp_filter` drops the server's replies. Leave the sysctl set on down, as
  `wg-quick` does.

Check for `nft` alongside `wg` and `iproute2`.

### DNS and endpoint resolution

Initial full mode requires working systemd-resolved and a host resolver path
that actually uses it. Set the regional DNS addresses on the VPN link, a `~.`
routing domain, and appropriate default-route policy through a typed adapter.
Mesh leaves host DNS unchanged. Teardown reverts only the VPN link's settings.
See [Ubuntu's WireGuard DNS guidance](https://ubuntu.com/server/docs/how-to/wireguard-vpn/common-tasks/)
and [`resolvectl`](https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html).

`~.` alone does not override other links' more-specific routing/search domains.
Equal matching domains can send queries over multiple links. Preflight and
network-change reconciliation must detect these conflicts and reject unsupported
full-mode resolver setups, rather than promise that all DNS uses the VPN.
This follows [systemd-resolved routing](https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html).
No arbitrary resolver-file replacement or new DNS proxy is included. Full mode
requires systemd-resolved on every distro, rather than separate resolvconf or
NetworkManager adapters. The installer handles the setup check below.

For a running Full tunnel, subscribe to resolver/link changes and recheck the
complete supported policy. If resolved loses the VPN-link settings, attempt one
bounded reapply of those owned settings. During that repair the runtime is
unknown/connecting, not healthy Full. If exclusivity cannot be restored, or
another link gains a conflicting domain, fail the network transition, suppress
automatic restart, and tear down owned VPN state. Once cleanup is confirmed,
report disconnected with no active mode, retain Full as the selected preference,
and expose `vpn_failed` plus a required doctor DNS failure. A subsequent up
requires passing preflight again. Incomplete teardown remains unknown or
disconnecting and blocks conflicting starts.

This is an explicit failed connection, not continued Full service. Resolver
event detection/reapply is not atomic with DNS queries. A conflicting manager
can create a leakage window before detection, and successful teardown restores
ordinary underlay connectivity/DNS. The v1 claim is supported steady-state VPN
DNS routing, not fail-closed DNS under arbitrary external reconfiguration. A
stronger guarantee requires a separately specified enforcement policy.

Resolve the WireGuard hostname with normal host DNS during `up`, before
installing VPN routes/DNS. When a Full tunnel is already installed, such as when
switching clients or reconnecting, use the outside-tunnel lookup described below
instead, so a dead tunnel can't block the new endpoint. A server deploy changes
its public IPv4 and leaves a connected tunnel dead. There is no automatic
re-resolution or polling.

The daemon checks "is the server responding?" only for human `status`, `doctor`,
and `refresh`. JSON `status` never shows the hint, so it skips the check. If the
kernel's latest handshake is under 60 seconds old, the answer is yes, with no
traffic. Otherwise the daemon sends one DNS query through the tunnel to the
regional DNS address with a 2-second timeout. A reply means yes.
Handshake age alone can't give a 1-minute bound: keepalives don't update it, and
a healthy tunnel only rehandshakes about every 2 minutes. This probe only
drives the hint below. It doesn't change the observation mapping.

When the server isn't responding, human `status` output and a `doctor` warning
suggest `cloudgateway refresh`. Status JSON is unchanged.

Only `refresh` and `list --refresh` try to recover a changed server IP. They
run the same check first. If the server is responding, everything stays inside
the VPN and the inventory refresh runs as usual. If not, the daemon re-resolves the
server's hostname outside the VPN: one query for only that hostname, sent to
the physical link's DNS servers from a socket carrying the WireGuard fwmark.
Mesh can use normal host DNS for this. If the IP changed, the daemon updates the peer
endpoint in place with `wg set`, leaving routes and DNS alone, then the
inventory refresh runs. No other lookup leaves the tunnel. If refresh can't fix
it, `down` then `up` still works. The source-address rules keep SSH available.

### Observations, failure, and persistence

Persist operation reservation/confirmation using the macOS protocol. Flush the
accepted ID before confirming any effect. Unconfirmed work expires after 30
seconds. Keep separate creation/ordinary result slots and bounded 600-second
receipts/results, with managed-update recovery separately durable. Restart may
make an ordinary result unknown. A recovery journal records local networking
intent, not proof that a cloud mutation did or did not happen.

Track desired client/mode separately from observed interface, addresses, routes,
rules, resolver state, and runtime readiness. A new interface is not proof of
internet reachability; a historical handshake is not a current connectivity test.
Use this normative mapping, without traffic probes or connection history:

| Evidence | Public tunnel state and applied mode |
| --- | --- |
| Exact owned profile, addresses, peer configuration, routes/rules, and required DNS match the committed journal, with no transition | `connected`, current observation, validated active mode |
| Confirmed start or repair is still applying configuration | `connecting`, active mode only after the whole mode policy is verified |
| Stop/failed-transition cleanup is running and owned resources remain | `disconnecting`, active mode null once its policy no longer holds |
| Fresh observation proves all owned interface/routes/rules/DNS changes absent or reverted | `disconnected`, current observation, active mode null |
| Read succeeds but state is partial, mismatched, or restart ownership is not reconciled | `unknown`, current observation, active mode null |
| Network observation fails after a prior successful read | Retain last observed coarse state with `stale`, active mode null, never treat it as current readiness |
| No usable observation has ever completed | `unknown` with `unavailable` observation, active mode null |

Endpoint/handshake failure alone does not erase verified configured state.
Keep routes/DNS and active mode. `connected` means configured runtime readiness,
not verified end-to-end delivery. A kernel tunnel can remain configured after
the daemon crashes. Before reporting a current applied client/mode after
restart, compare actual owned resources with the committed profile/hash/mode.
Redact profile identity when the current account cannot see it. Remove safety
requires a fresh inactive observation; stale/unavailable data cannot authorize it.
Down succeeds only after the fresh all-owned-resources stop predicate above.

Preflight failures preserve the current tunnel. During setup/replacement,
journal only owned changes and roll them back on failure. Attempt restoration
of a previous working profile, and report the actual state if restoration fails.
Incomplete cleanup remains visible and blocks conflicting new work. Persist
explicit down intent before teardown so a daemon crash cannot resurrect it.
Daemon restart reconciles owned state, without adopting an unrelated interface
with a matching name. Preserve unrelated UFW/nftables rules and marks, never
flush global tables. See [nftables verdict semantics](https://netfilter.org/projects/nftables/manpage.html).

### Intent, logout, and boot

The daemon keeps one durable network intent record: a monotonic revision,
account/session generation, profile/mode identity, transition phase, and
start/reconnect suppression. Every network effect is serialized against it and
persisted before the kernel changes. A newer revision wins over older queued
work, and root recovery advances the same revision.

Down first persists a stop/suppression revision, then removes resources.
Acknowledgment of intent is distinct from confirmed-stop success. No start from
an older revision can run after that point. The stop path never requires a
Firebase account. A failed persistence/observation step cannot be reported as a
successful down.

Logout first persists the invalidated auth generation, a cleanup marker, and
start suppression, then clears usable credentials. It cancels uncommitted
starts/repairs/reconnects and rolls back a partial start, while preserving a
fully established tunnel. Failure reports incomplete auth cleanup and retains
the marker for recovery, rather than claiming suppression succeeded. After a
restart, the daemon processes any logout/down marker before running a journaled
start, and a revoked generation stays revoked.

Start the daemon at boot. After a reboot, reconnect the last client and mode
when the saved intent was connected, with no `down` or logout since. Running
`down` before a reboot keeps the VPN off. This intentionally differs from
macOS, which stays off after a reboot, because a headless VM has nobody to
reconnect it after an automatic update reboot. Boot resume needs the same
retained account authorization as bare `up`, and retries the endpoint lookup
until the network is ready, reporting `connecting`. Host setup and network
failures, such as resolved starting after the daemon, retry the same way for
up to 5 minutes. Do not add `--autostart` to
the CLI. `network-online.target` is
[boot ordering, not a runtime availability monitor](https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html#network-online.target).

When an established tunnel loses its endpoint, retain routes/DNS until the user
runs `refresh` or `down`. Do not restore ordinary underlay access as an
endpoint-recovery strategy. Resolver-policy failure has the
explicit failed-teardown behavior above. This is functional full routing with
the same absence of a kill-switch promise as macOS. Start, stop,
rollback, replacement, interface deletion, and boot may have underlay windows.
A fail-closed firewall guarantee needs a separate product/lifecycle design.

## Installation, update, and versioning

Release `linux-v1.0.0`, then `linux-v1.0.1`, `linux-v1.0.2`, and so on for the
launch series. Each different shipped artifact set gets a new version. Keep
release SemVer, IPC version, JSON schema version, and storage schema independent.
Do not constrain future feature releases to patch bumps if adopting
[Semantic Versioning](https://semver.org/) terminology.

Retain JSON `version` and `build` as strings. Proposed Linux mapping:
`version = "1.0.0"`, `build = "1.0.0"`, with the same mapping in update targets.
There is no separate build counter. Keep the human version formatter
`CloudGateway 1.0.0 (1.0.0)` to preserve its shape. The duplicate value is the
explicit cost of retaining schema 1. A cleaner single-field schema would be
a separate public contract change. Update `target.codeHash` is the lowercase hex
SHA-256 of the signed release manifest, which fits the 64-character format macOS
validates.

Publish amd64/arm64 archives and a signed manifest binding version, architecture,
asset size/hash, runtime compatibility, and all installed executables. Verify
the exact manifest bytes with a pinned release key before trusting hashes or
extracting assets. Go supplies
[Ed25519 verification](https://pkg.go.dev/crypto/ed25519); the shell bootstrap can
use a verified available OpenSSL implementation with the correct Ed25519 mode.
The initial installer itself needs a trusted HTTPS distribution path, with an
inspectable download option. A checksum beside an untrusted archive alone does
not authenticate either file.

The installer detects architecture, parses
[`os-release`](https://www.freedesktop.org/software/systemd/man/latest/os-release.html)
as data, checks actual kernel/tools/resolver/systemd capabilities, enrolls the
operator, and installs root-owned binaries/units. No OS files are sourced.
The script installs a missing dependency through the system package manager
only after the user answers yes. That's a few lines to find `apt-get`, `dnf`, or
`pacman`, and is separate from publishing packages. There is no CloudGateway
APT/RPM repository and no package manager requirement during ordinary CLI use.

The installer also checks that systemd-resolved is the system resolver: the
service is running, `/etc/resolv.conf` points at its stub, and links have
upstream DNS servers. Ubuntu Server already works this way. A missing or
inactive resolved doesn't block installation. Mesh doesn't touch host DNS and
works without it. Full refuses with a clear error, and `doctor` shows the fix.

On other distros, installing the package isn't enough. On Debian with ifupdown,
the DHCP client writes `/etc/resolv.conf` itself, so resolved can end up unused
or without upstream servers. Oracle Linux needs NetworkManager set to
`dns=systemd-resolved`. A wrong switch breaks DNS for the whole machine. The
installer offers to switch with a Y prompt only on distros where that switch
has been tested, and prints the steps elsewhere.

Installing a new release should just work. Linux has none of the macOS update
constraints: no OS-owned extension that refuses replacement, and no separate
approval or restart. The tunnel also outlives the daemon process. The WireGuard
interface, routes, rules, nftables table, and resolver settings are kernel and
resolved state, so a restarted daemon adopts them from its journal, the same as
crash recovery.

The installer verifies the release, extracts it into a root-owned versioned
directory, atomically points `current` at it, and restarts the daemon. On
SIGTERM, the daemon stops accepting new work, waits up to a short bound for
running cloud requests, persists receipts and results, and exits without
touching the tunnel. The new daemon migrates its stored state, adopts the
running tunnel, and continues. A request still running at the bound can end as
unknown, as the parity contract already allows. Nothing is replayed.

Each release reads the previous release's journal and state formats, so an
ordinary update always adopts the tunnel. If the daemon finds a journal it
can't read, it removes owned resources by their fixed identities and reports
disconnected, rather than guessing. The installer refuses a downgrade across a
storage format change. Keep the previous release directory for manual rollback.

`cloudgateway update` keeps its macOS meaning: activate the installed runtime.
On Linux it restarts the daemon when the running version differs from `current`,
and is a no-op when they match. That only happens when an install skipped or
failed its restart. The daemon persists the update record before it exits,
systemd restarts it on the new version, and the new daemon completes the record.
`status --operation` works across the restart, and CLI detach doesn't cancel it.

Linux emits `prepared`, `activating`, `checking_readiness`, and `completed`. The
tunnel stays up, so Linux never emits `stopping` or `reconnecting` and never
returns `disconnect_required`. `--allow-disconnect` is accepted for parity and
has no effect. Apple's approval and restart phases stay in the schema but are
never emitted. A new CLI and an older running daemon only talk within a
compatible IPC version, and otherwise return the existing version error until
the restart finishes. Linux help and recovery text use platform wording without
changing JSON shapes or exit categories.

Uninstall stops only managed networking, restores owned DNS/routes, deletes the
owned nftables table, disables the service, and removes only owned installation
files. Preserve
account data unless purge is explicitly chosen. Do not delete cloud clients,
remove distro dependencies, or disturb another network manager.

## Validation and remaining engineering gates

The [Linux client](../Frontend/Linux/README.md) is implemented. `./scripts/test.sh linux`
runs its host-free checks, including macOS fixtures ported to Go and a
simulated Ubuntu host for network tests. No VM experiments have run.
Privileged route/DNS checks require actual disposable VMs with console
recovery, not the ARM macOS development host.

Known limitations to settle on VMs before release:

* Full sends replies for DNAT'd inbound traffic, such as Docker `-p` or
  libvirt port forwards, into the tunnel, as `wg-quick` does. A masked
  connection mark could keep them on the underlay.
* The `from <address> lookup main` rules skip later host policy rules, such as
  multi-NIC `routing-policy` without a priority. `goto` to an owned `nop` rule
  would keep them.
* VPC IPv6 is usually global unicast on AWS and GCE. Traffic to the VM's own
  subnet stays out of the tunnel, but other subnets in the VPC go through it.
* Full rejects any search or routing domain on another link with DNS servers.
  netplan `use-domains` or NetworkManager DHCP search domains block it.
* `503 AUTH_UNAVAILABLE` and edge HTML errors keep the session without granting
  offline starts. Only transport failures allow cached authorization.

Release requires evidence for:

* Ubuntu 24.04/26.04, amd64/arm64, headless boot, IPv4-only and dual-stack
  underlays, kernel WireGuard, resolved, and restrictive supported firewalls.
* Full: controlled IPv4/IPv6 internet egress and system DNS through the region,
  including inner IPv6 over IPv4 transport, resolver restarts, DHCP changes,
  and MTU-sensitive traffic on jumbo-frame cloud NICs. Verify regional upstream
  IPv6 independently.
* Mesh: same-account IPv4/IPv6 inbound/outbound reachability within and across
  regions, cross-account denial, and unchanged ordinary internet/DNS behavior.
  Host service bindings/firewalls still govern inbound access.
* Lifecycle: caller detach, failed acceptance output, daemon crash in every
  mutation phase, explicit down, reboot resume and `down` before reboot,
  logout/account change, manual `down`/`up` after a server IP change, partial
  cleanup, `netplan apply`/networkd restart, and installing a new release while
  connected.
* VM safety: SSH from a source address not seen before, LAN/VPC, metadata,
  DHCP, and NTP reachability in Full, LAN/VPC traffic to the mesh address being
  dropped, VPC/mesh collisions, competing VPN/rule/mark allocations, strict
  `rp_filter`, and unsupported resolver domains. Verify failures leave an
  existing tunnel untouched.
* Authority/secrets: rejected UID/path/argv/hook injection, socket permissions,
  account redaction, revoked/downgraded access, refresh rotation, and no secrets
  in process lists, output, journal, or diagnostics.

The highest-risk implementation spikes are full-mode DNS exclusivity, SSH and
local-route behavior in Full, and the daemon adopting a running tunnel on
restart. Existing backend gaps
are create idempotency and per-device remote revocation. Neither requires new endpoints
to ship parity, but neither should be promised by the Linux client.
