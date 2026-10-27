# Linux CLI implementation

The client is implemented in [`Frontend/Linux`](../Frontend/Linux/README.md)
and tested host-free. Checked items are implemented. Every Verify, Prove, and
VM item still needs real Ubuntu evidence. Start from `linux-cli` and use the
[research](../docs/linux-cli-research.md) and [parity contract](../docs/linux-cli-parity.md).
Ubuntu 24.04/26.04 LTS, amd64/arm64, are proposed release targets, pending
actual validation.

## 1. Freeze the contract and prove the network boundaries

- [x] Capture macOS argv, JSON, human-output, error/exit, selector, account,
  operation, and mode fixtures before porting implementation
- [x] Establish `Frontend/Linux/` Go module with the CLI, one daemon, and a
  network package with no HTTP/Firebase imports, without refactoring the
  shipped Apple packages
- [x] Add host-free `linux` validation to `scripts/test.sh` and document the Go
  toolchain pin and reproducible release build
- [ ] Prove daemon socket authority and enrolled UID
- [ ] Set up disposable Ubuntu 24.04/26.04 test VMs, amd64 and arm64, with
  console access for recovery. None exist yet
- [ ] On those VMs, prove owned dual-stack policy routing, resolved DNS
  exclusivity, and the Full-mode server hostname lookup over the physical link
  before committing to the production adapter
- [ ] Prove Full keeps SSH from a new source address, LAN/VPC, metadata, DHCP,
  and NTP working through `suppress_prefixlength 0` and the source-address rules
- [ ] Check which owned rules/routes networkd removes on `netplan apply` and
  networkd restart, and that the daemon's reapply restores them
- [ ] Specify the exact service unit and supported resolver configurations.
  Verify the documented observation, intent-revision, update, and boot policies

Checkpoint: runnable local help/version/parser with compatible output, plus
written VM spike evidence. Do not claim full mode from an interface-up check.

## 2. Auth and authorized inventory

- [x] Implement device proof/create/poll/custom-token exchange and terminal/QR
  behavior with the same timeout, cancellation, and login JSON contract
- [x] Add serialized Firebase refresh, atomic credentials, identity/project
  continuity, safe errors, access checks, and session-generation fences
- [x] Implement rules-constrained Firestore reads and config retrieval
- [x] Preserve role downgrade/denial, complete-refresh publication, hash/secret
  separation, transport-only offline fallback, sorting, indices, and selection
- [x] Implement auth status/logout, list/ls/long/region, and refresh without
  connecting a VPN or leaking another account's cached metadata

Checkpoint: browser-approved login and complete online/offline inventory on a
headless VM. No service-account credentials and no new read endpoints.

## 3. Daemon operations and mesh networking

- [x] Implement versioned IPC and reserve/flush/confirm/poll/detach semantics
- [x] Add the durable intent record, including accountless down, logout
  suppression, and restart reconciliation
- [x] Add bounded receipts, ordinary/creation result slots, account redaction,
  and restart unknown outcomes without cloud mutation replay
- [x] Implement allowlisted config parser and private pipe-based `wg` input
- [x] Add owned interface/address/MTU/route/rule/mark lifecycle and cleanup
  journal, with fixed resource identities. MTU is min(route MTU, 1500) − 80
  unless the config sets one
- [x] Add the owned `inet cloudgateway_client` nftables table and drop tunnel
  address traffic arriving on other interfaces
- [x] Watch owned rules/routes over netlink and reapply any that disappear
- [x] Implement up/down/mode/status with separate desired and observed state
- [x] Keep bare signed-out down and down during add available
- [ ] Verify same/cross-region IPv4/IPv6 mesh reachability and cross-account
  denial while ordinary internet/DNS remain on the underlay

Checkpoint: detached SSH caller can recover an accepted mesh operation; failures
and daemon restart leave no unowned changes or secret output.

## 4. Full routing, DNS, and recovery

- [x] Install both-family full policy routing, `suppress_prefixlength 0`, and
  source-address rules that follow DHCP address changes
- [x] Add Full's connection-mark restore and `src_valid_mark`, and verify on a
  strict `rp_filter` host
- [x] Apply exclusive supported resolved policy, with conflict detection and
  VPN-link-only teardown. Implement the documented running-policy repair/failure
  transition, including its explicit underlay-restoration behavior
- [x] Resolve the endpoint during `up` before installing routes, and outside the
  tunnel when a Full tunnel is already up
- [x] Add the on-demand server check: handshake under 60s, else a 2-second
  DNS query through the tunnel. Skip it for JSON status. Verify the probe works
  in both modes
- [x] When the server isn't responding, make refresh re-resolve its hostname
  outside the VPN and update the endpoint in place. Verify recovery after a
  server IP change in both modes
- [x] Show the refresh hint in human status output
- [ ] Verify regional IPv4/IPv6 egress and tunnel DNS on IPv4-only/dual-stack VMs
- [ ] Verify overlap, firewall/mark/rule collision, SSH safety, resolver restart,
  MTU on jumbo-frame NICs, interrupted transition, rollback, and
  incomplete-cleanup behavior
- [ ] Prove crash recovery, reboot resume of the last connected client/mode,
  `down` before reboot staying off, and logout suppression

Checkpoint: both modes meet the network acceptance matrix. Document the absence
of a kill-switch guarantee and which local routes stay outside the tunnel.

## 5. Cloud add/remove and diagnostics

- [x] Implement named regional add/capacity using existing endpoints
- [x] Preserve conservative unknown creation results and no automatic retries
- [x] Implement explicit-consent removal, fresh authorization, inactive-target
  check, pre-dispatch durable eviction, and post-success warning precedence
- [ ] Verify target identity across account changes, concurrent down, missing
  config/disabled region, lost response, daemon restart, and stale index recovery
- [x] Add read-only Linux doctor probes with existing report/exit semantics,
  including a server-reachability warning that suggests refresh

Checkpoint: full public command surface except installed-runtime update, with
compatible NDJSON and safe diagnostics. Cloud mutation validation uses isolated
test accounts/clients rather than ordinary production inventory.

## 6. Installation, runtime update, and release

- [ ] Build amd64/arm64 assets and signed manifests for `linux-v1.0.0`
- [x] Implement inspectable shell installer, architecture/capability checks,
  explicit optional dependency installation, UID enrollment, and private state
- [x] Install versioned releases with an atomic `current` switch, then restart
  the daemon. On SIGTERM it waits briefly for running cloud requests and leaves
  the tunnel up
- [ ] Prove a daemon restart adopts a running tunnel without disconnecting
- [x] Read the previous release's journal/state formats. On an unreadable
  journal, remove owned resources by fixed identity and report disconnected
- [x] Implement update as restart-to-installed-version, with no-op and a
  persisted update record that survives the restart. Accept
  `--allow-disconnect` with no effect
- [x] Refuse downgrades across a storage format change and keep the previous
  release directory
- [x] Keep JSON version/build strings mapped to the same release version, with
  `codeHash` as the manifest SHA-256
- [x] Implement owned-resource uninstall and opt-in data purge without deleting
  cloud clients or shared distro packages
- [ ] Run contract differential checks, targeted `scripts/test.sh` validation,
  and the real Ubuntu VM matrix, recording versions and sanitized evidence
- [ ] Publish support wording and user/operations docs only after evidence exists

Checkpoint: all macOS CLI commands have meaningful Linux behavior. No disabled
update stub or untested distro claim counts as parity. Additional distributions,
P2P, direct netlink, encrypted-secret integration, remote revocation, backend
idempotency, and a kill switch are separate follow-up work.
