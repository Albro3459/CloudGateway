# Linux CLI research

Research date: 2026-10-26. Reference implementation: `32dae6c` on local `main`.
The existing `cli` branch had no unique commits. It was rebased onto that commit
and renamed `linux-cli`. Nothing was pushed or committed for this research.

This is a proposed implementation design. There is no Linux client, installer,
release, or completed Linux VM validation yet. Source inspection establishes
backend capability, not the state of deployed servers.

## Scope and original decisions

This document supersedes the Linux proposal in
[Plan Cross-Distro Linux CLI](t3-thread://v1/d1fc7405-49b5-4991-b988-486ff20689a2),
including the final user corrections in that thread. The current macOS CLI is
the public compatibility baseline. See the [parity contract](linux-cli-parity.md),
[implementation checkpoints](../TODO/linux-cli.md), and
[design review](linux-cli-review.md).

| Earlier proposal | Updated decision |
| --- | --- |
| Direct Firebase REST reads | Keep. Use existing regional APIs for mutations |
| Named client creation | Keep, using macOS `add <region> <name>` |
| Required `up --mode` | Superseded by current `mode full\|mesh`, saved per-account preference, Full default |
| Number from the last displayed list | Superseded by current region-local indices from settled inventory |
| `login`, `regions`, `--autostart` examples | Use the implemented macOS command surface, with no added public commands/flags |
| Daemon from v1 | Keep. Accepted work must survive CLI/SSH detachment |
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

Recommend Go under `Frontend/Linux/`, with a thin `cloudgateway` executable,
an unprivileged background controller, and a small privileged networking service.
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

### Processes and local authority

* `cloudgateway`: parser, rendering, terminal interaction, and IPC only. Help and
  version work locally without services, credentials, or network access.
* `cloudgatewayd`: dedicated unprivileged system account. Owns device login,
  Firebase tokens/refresh, inventory/cache, account generations, selections,
  modes, operation reservations/results, and cloud mutations. Runs independently
  of desktop login sessions.
* `cloudgateway-netd`: root service with bounded capabilities. Owns one managed
  kernel interface, retained tunnel secret records, route/rule/mark allocation,
  resolver integration, observed network state, and an interrupted-change journal.
  It has no Firebase SDK/client, release downloader, or shell execution endpoint.

This preserves the macOS separation between account/controller work and the
privileged VPN runtime. Linux interface and routing changes need
[`CAP_NET_ADMIN`](https://man7.org/linux/man-pages/man7/capabilities.7.html).
That capability alone does not grant resolver D-Bus or privileged file access.
Use root initially for the narrow network service and restrict it with systemd
capability and filesystem controls. Do not apply `PrivateNetwork` or a sandbox
that hides the host network it must configure. Exact unit settings need a spike
on both supported Ubuntu versions, rather than copying latest-systemd options.

Enroll one administrator-designated local operator UID during installation.
The public socket accepts that UID and root. The private networking socket
accepts the controller service UID and root. Check filesystem socket permissions
and kernel [`SO_PEERCRED`](https://man7.org/linux/man-pages/man7/unix.7.html) on
every connection. Never trust a UID/account claim supplied in a request.
Cloud admin status does not confer local machine control. Root is the recovery
authority, not a second Firebase account. Other local users cannot inspect or
stop the operator's connection.

Bind account-bound controller requests to the enrolled UID, Firebase UID, and
session generation. Bare down requires local operator authority, with no account
or usable auth credentials. The network service accepts bounded typed operations and opaque
profile IDs, never arbitrary executable names, paths, shell snippets, or routes.
Use bounded length-framed local messages and explicit IPC versions. Canonical
profile identity stays `signedInUID/regionId/clientId`, including admin views of
another owner's client. Root-owned installation directories prevent an ordinary
user from replacing the privileged executable or its dependencies.

### Secrets and persisted state

Keep metadata caches separate from credentials and tunnel secrets. The
controller's service-owned directory is `0700`, with atomically replaced `0600`
credential files. The networking service keeps structured secret records in a
root-owned `0700` directory with `0600` files. Do not persist downloaded config
documents in metadata, operation logs, journals, or diagnostic output. An
opaque reference identifies the retained secret record.

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
services. Never print raw HTTP error bodies, tokens, keys, full configs,
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
   digest. Keep the original secret in memory for that attempt only.
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
group. Ordinary-user instance queries must include `ownerUid == authenticatedUID`
on every page. Only a verified admin may omit that filter. Rules are
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

Use bounded pages with explicit `__name__` ordering and an exclusive full-document
reference cursor. `runQuery` uses
[StructuredQuery cursors](https://firebase.google.com/docs/firestore/reference/rest/v1/StructuredQuery),
not `documents.list` page tokens. Handle response entries without a document.
Start a bounded read-only transaction for a paged inventory read, reuse its
transaction ID across pages/queries, and release it on completion/cancellation.
The [runQuery contract](https://firebase.google.com/docs/firestore/reference/rest/v1/projects.databases.documents/runQuery)
supports this consistency selector and reports the transaction in a separate
first response. An expired transaction fails the refresh. Replace the authorized
cache only after every page and a final current access/role check succeeds.
Keep the owner filter and query snapshot across pages, and filter statuses
locally to avoid unnecessary new composite indexes.

Mirror account-generation fences, role-downgrade invalidation, authorized config
hashes, and classified offline fallback from the macOS controller. Only a
transport failure with previous account authorization permits offline starts.
Denial, malformed replies, and incomplete reads do not grant offline access.
An old role-less cache requires fresh authorization. No new cache age TTL is
introduced as an accidental Linux policy difference.

The code's inventory stale threshold is 60 seconds, despite older Apple prose
mentioning 30. Port the scheduler from source: active polling, idle backoff,
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
under the existing retention policy. A disconnected network service or unknown
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
service own resource identity, rollback, DNS, and observed state explicitly.
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

### Routing and VM management

Allocate one interface and dedicated route tables, rule priorities, and marks
for both address families. Record the allocation and reject collisions.
Exempt marked outer WireGuard packets from the tunnel to prevent recursion.
WireGuard's [routing reference](https://www.wireguard.com/netns/) explains this
fwmark policy and the usual preservation of nondefault main-table routes.
Porting that pattern without reviewing its exceptions would not establish the
requested full-route behavior.

Preflight must inspect actual routes, local addresses, other VPNs, and resolver
paths. A cloud VPC overlapping `10.0.0.0/16` is a concrete blocker, including
local addresses or more-specific routes that capture regional DNS. Reject
known conflicts before mutation and report prefixes, rather than silently
choosing VPC or mesh ownership. Identical destination addresses require an
operator addressing decision. Do not change the fleet range in this ticket.

Require a root-owned deployment policy before Full activation, independently of
whether the caller appears to use SSH. The policy explicitly declares either
console administration or fixed administrator-approved management destination
prefixes. Use dedicated higher-priority underlay route rules for those prefixes,
bound to the validated physical link/gateway. Do not infer authority from
`SSH_CONNECTION`, caller ancestry, or local socket credentials.

This protects replies to existing and new management sessions only when their
remote source falls within a configured prefix. A new management source outside
that set is not protected. An administrator can choose a trusted management
network, VPN, or bastion address rather than a changing laptop address. Require
console recovery during initial validation. Preflight checks the policy's
routes in both relevant families, rejects conflicts, and refuses Full without
an explicit valid policy. Link/gateway changes require revalidation.

Required metadata/cloud-service bypasses are separate explicit policy entries.
Do not silently bypass all RFC1918 networks or all link-local space. OCI
link-local space also carries non-metadata services. Never learn or persist
exceptions from traffic or retain SSH source history. The public CLI gains no
Linux-only routing flags. Full-route claims disclose these approved static
management/service exceptions, without extending them to general internet traffic.

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
No arbitrary resolver-file replacement or new DNS proxy is included. A later
resolvconf adapter can support other Debian/Arch setups after validation.

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

Resolve the WireGuard hostname before replacing routes/DNS. Retain its hostname
separately from the current numeric endpoint. On relevant network changes or
sustained handshake failure, retry endpoint resolution with bounded backoff.
The [upstream re-resolution helper](https://git.zx2c4.com/wireguard-tools/plain/contrib/reresolve-dns/reresolve-dns.sh)
shows that endpoint refresh is an explicit userspace responsibility.

Recovery cannot depend solely on DNS inside a dead tunnel. Prove interface-scoped
resolution of only the WireGuard infrastructure hostname through the physical
link before supporting that host setup. Reject configurations where the proposed
method cannot bypass a dead tunnel without reopening general application DNS.
This is a narrow control-plane exception, not general DNS fallback.

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
| Helper observation is lost after a prior successful read | Retain last observed coarse state with `stale`, active mode null, never treat it as current readiness |
| No usable observation has ever completed | `unknown` with `unavailable` observation, active mode null |

Endpoint/handshake failure alone does not erase verified configured state.
Keep routes/DNS and active mode, and report transport uncertainty through doctor
when supported evidence exists. `connected` means configured runtime readiness,
not verified end-to-end delivery. A kernel tunnel can remain configured after
either service crashes. Before reporting a current applied client/mode after
restart, compare actual owned resources with the committed profile/hash/mode.
Redact profile identity when the current account cannot see it. Remove safety
requires a fresh inactive observation; stale/unavailable data cannot authorize it.
Down succeeds only after the fresh all-owned-resources stop predicate above.

Preflight failures preserve the current tunnel. During setup/replacement,
journal only owned changes and roll them back on failure. Attempt restoration
of a previous working profile, and report the actual state if restoration fails.
Incomplete cleanup remains visible and blocks conflicting new work. Persist
explicit down intent before teardown so a service crash cannot resurrect it.
Service restart reconciles owned state, without adopting an unrelated interface
with a matching name. Preserve unrelated UFW/nftables rules and marks, never
flush global tables. See [nftables verdict semantics](https://netfilter.org/projects/nftables/manpage.html).

### Authority across the two services

Netd is the sole writer of the durable network intent record. It includes a
monotonic revision, account/session generation, profile/mode identity, transition
phase, and start/reconnect suppression. Every network effect is serialized
against that revision. Controller requests name the expected revision; stale
start/repair/update-reconnect requests fail rather than overwrite newer intent.
Root recovery advances the same revision. On disagreement, netd's newer record
wins and the controller observes/reconciles it instead of replaying local work.

Down first advances and persists netd's stop/suppression revision, then removes
resources. Acknowledgment of intent is distinct from confirmed-stop success.
No start from an older revision can run after that barrier. The stop path never
requires a Firebase account. A failed persistence/observation step cannot be
reported as a successful down.

Logout first persists the controller's invalidated auth generation and cleanup
marker and clears usable credentials. It then requests a netd suppression
barrier that cancels uncommitted starts/repairs/reconnects while preserving a
fully established tunnel. A start already committed before the barrier remains
that retained tunnel. A partial start is rolled back. Successful logout waits
for durable suppression acknowledgment; failure reports incomplete auth cleanup
and retains the marker for recovery, rather than claiming suppression succeeded.

Start/repair grants also require the live authenticated controller channel.
Channel loss suppresses new start effects but leaves an established tunnel and
stop/cleanup available. After either service restarts, no journaled start or
update reconnect may run until the controller restores its persisted generation,
processes any logout/down marker, and issues a matching fresh grant. A revoked
generation is never restored from netd's journal. This restart handshake closes
the gap between controller-local auth invalidation and independent netd recovery.

Start services at boot, with automatic VPN connection disabled by default to
match macOS's separation between launch and connect. A proposed opt-in root
deployment setting may resume a specific enrolled account/config/mode after
reboot. It must require retained account authorization, obey persisted down
intent, and be suppressed by logout. Do not add `--autostart` to the CLI.
Distinguish daemon crash recovery from a fresh OS boot and explicit service
maintenance from user down. `network-online.target` is
[boot ordering, not a runtime availability monitor](https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html#network-online.target).

When an established tunnel loses its endpoint, retain routes/DNS, expose honest
observation/readiness evidence, and retry the endpoint. Do not restore ordinary
underlay access as an endpoint-recovery strategy. Resolver-policy failure has the
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
a separate public contract change.

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
Dependency installation uses Ubuntu repositories only when explicitly selected
in the installer. There is no CloudGateway APT/RPM repository and no package
manager requirement during ordinary CLI use.

Preserve macOS `update` semantics: activate/reconcile an already installed
privileged VPN runtime, rather than redefine it as a release downloader. Its
Linux target is **netd and its packaged network dependencies only**. The
controller/CLI are not replaced during that operation. The unchanged controller
owns the durable update result, captured config/mode, and reconnect workflow.

The root installer stages verified versioned assets and a signed target manifest.
A fixed root-owned launcher starts netd from a root-owned active-runtime selector.
Netd accepts only a staged target ID whose signature, hashes, paths, ownership,
and IPC/storage compatibility have been verified. It atomically persists the
target selector/recovery record, then requests systemd to restart its own unit.
The launcher verifies the selected assets before executing them. No caller path,
arbitrary executable, shell command, or user-writable release is accepted.

A matching target is a no-op. An active replacement requires `--allow-disconnect`
and confirmed stop. The controller observes the new helper's authenticated
target version/hash and readiness, then supplies a fresh revision-bound grant
to reconnect only the captured still-authorized client/mode. New down/logout
suppression wins over reconnect. Initially off stays off. CLI detach does not
cancel the operation; controller restart resumes only from its durable update
record after the generation/suppression handshake. An ordinary operation result
can still be unknown after restart, as specified by the parity contract.

The installer replaces CLI/controller in a separate disconnected-only maintenance
phase with no live operation/update. It first drains the controller and confirms
netd start suppression, then switches root-owned binaries and restarts the
controller. Otherwise it stages and reports the prerequisite rather than
replacing the update owner. New CLI and old controller communicate only within
an explicitly compatible IPC window; incompatible versions return the existing
version error. All shipped runtime combinations must be covered by the manifest.

Keep rollback within compatible storage/IPC versions. Prove this sequence in the
packaging checkpoint before calling update implemented. Apple-specific
approval/restart phases remain schema enum values but are not fabricated Linux
events. Linux help/diagnostics/recovery suggestions use platform wording without
changing JSON shapes or exit categories.

Uninstall stops only managed networking, restores owned DNS/routes, disables
service/socket activation, and removes only owned installation files. Preserve
account data unless purge is explicitly chosen. Do not delete cloud clients,
remove distro dependencies, or disturb another network manager.

## Validation and remaining engineering gates

No tests/builds or VM experiments ran for this docs-only change. The
[parity contract](linux-cli-parity.md) identifies existing macOS fixtures to
reuse. Add a `linux` target to `scripts/test.sh` when implementation lands.
Host-free validation belongs there; privileged route/DNS checks require actual
disposable VMs with console recovery, not the ARM macOS development host.

Release requires evidence for:

* Ubuntu 24.04/26.04, amd64/arm64, headless boot, IPv4-only and dual-stack
  underlays, kernel WireGuard, resolved, and restrictive supported firewalls.
* Full: controlled IPv4/IPv6 internet egress and system DNS through the region,
  including inner IPv6 over IPv4 transport, resolver restarts, DHCP changes,
  and MTU-sensitive traffic. Verify regional upstream IPv6 independently.
* Mesh: same-account IPv4/IPv6 inbound/outbound reachability within and across
  regions, cross-account denial, and unchanged ordinary internet/DNS behavior.
  Host service bindings/firewalls still govern inbound access.
* Lifecycle: caller detach, failed acceptance output, service crash in every
  mutation phase, explicit down, boot policies, logout/account change, endpoint
  replacement/dead DNS, partial cleanup, and signed runtime upgrade/rollback.
* VM safety: SSH return paths, configured management/cloud-service exceptions,
  VPC/mesh collisions, competing VPN/rule/mark allocations, and unsupported
  resolver domains. Verify failures leave an existing tunnel untouched.
* Authority/secrets: rejected UID/path/argv/hook injection, private socket
  permissions, account redaction, revoked/downgraded access, refresh rotation,
  and no secrets in process lists, output, journal, or diagnostics.

The highest-risk implementation spikes are full-mode DNS exclusivity,
endpoint bootstrap during tunnel failure, VM management routing, two-service
recovery, and installed-runtime activation. Existing backend gaps are create
idempotency and per-device remote revocation. Neither requires new endpoints
to ship parity, but neither should be promised by the Linux client.
