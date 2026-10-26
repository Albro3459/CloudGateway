# Linux CLI implementation

Planning only. No Linux runtime, installer, or VM evidence exists yet.
Start from `linux-cli`, updated to `32dae6c`, and use the
[research](../docs/linux-cli-research.md), [parity contract](../docs/linux-cli-parity.md),
and [review record](../docs/linux-cli-review.md). Ubuntu 24.04/26.04 LTS,
amd64/arm64, are proposed release targets, pending actual validation.

## 1. Freeze the contract and prove the network boundaries

- [ ] Capture macOS argv, JSON, human-output, error/exit, selector, account,
  operation, and mode fixtures before porting implementation
- [ ] Establish `Frontend/Linux/` Go module and separate CLI/controller/network
  service boundaries, without refactoring the shipped Apple packages
- [ ] Add host-free `linux` validation to `scripts/test.sh` and document the Go
  toolchain pin and reproducible release build
- [ ] Prove root network helper/controller socket authority and enrolled UID
- [ ] Set up disposable Ubuntu 24.04/26.04 test VMs, amd64 and arm64, with
  console access for recovery. None exist yet
- [ ] On those VMs, prove owned dual-stack policy routing, resolved DNS
  exclusivity, the Full-mode server hostname lookup over the physical link, and
  SSH/cloud management exceptions before committing to the production adapter
- [ ] Check which owned rules/routes networkd removes on `netplan apply` and
  networkd restart, and that netd's reapply restores them
- [ ] Specify exact service units and supported resolver configurations. Verify
  the documented observation, intent-revision, update, and boot policies

Checkpoint: runnable local help/version/parser with compatible output, plus
written VM spike evidence. Do not claim full mode from an interface-up check.

## 2. Auth and authorized inventory

- [ ] Implement device proof/create/poll/custom-token exchange and terminal/QR
  behavior with the same timeout, cancellation, and login JSON contract
- [ ] Add serialized Firebase refresh, atomic credentials, identity/project
  continuity, safe errors, access checks, and session-generation fences
- [ ] Implement rules-constrained Firestore reads and config retrieval
- [ ] Preserve role downgrade/denial, complete-refresh publication, hash/secret
  separation, transport-only offline fallback, sorting, indices, and selection
- [ ] Implement auth status/logout, list/ls/long/region, and refresh without
  connecting a VPN or leaking another account's cached metadata

Checkpoint: browser-approved login and complete online/offline inventory on a
headless VM. No service-account credentials and no new read endpoints.

## 3. Controller operations and mesh networking

- [ ] Implement versioned IPC and reserve/flush/confirm/poll/detach semantics
- [ ] Make netd the durable intent-revision authority, including accountless
  down, logout barriers, live-controller grants, and restart reconciliation
- [ ] Add bounded receipts, ordinary/creation result slots, account redaction,
  and restart unknown outcomes without cloud mutation replay
- [ ] Implement allowlisted config parser and private pipe-based `wg` input
- [ ] Add owned interface/address/MTU/route/rule/mark lifecycle and cleanup journal
- [ ] Watch owned rules/routes over netlink and reapply any that disappear
- [ ] Implement up/down/mode/status with separate desired and observed state
- [ ] Keep bare signed-out down and down during add available
- [ ] Verify same/cross-region IPv4/IPv6 mesh reachability and cross-account
  denial while ordinary internet/DNS remain on the underlay

Checkpoint: detached SSH caller can recover an accepted mesh operation; failures
and service restart leave no unowned changes or secret output.

## 4. Full routing, DNS, and recovery

- [ ] Install both-family full policy routing and approved underlay exceptions
- [ ] Apply exclusive supported resolved policy, with conflict detection and
  VPN-link-only teardown. Implement the documented running-policy repair/failure
  transition, including its explicit underlay-restoration behavior
- [ ] Resolve the endpoint during `up` before installing routes
- [ ] Add the on-demand server check: handshake under 60s, else a 2-second
  DNS query through the tunnel. Verify the probe works in both modes
- [ ] When the server isn't responding, make refresh re-resolve its hostname
  outside the VPN and update the endpoint in place. Verify recovery after a
  server IP change in both modes
- [ ] Show the refresh hint in human status output
- [ ] Verify regional IPv4/IPv6 egress and tunnel DNS on IPv4-only/dual-stack VMs
- [ ] Verify overlap, firewall/mark/rule collision, SSH safety, resolver restart,
  MTU, interrupted transition, rollback, and incomplete-cleanup behavior
- [ ] Prove crash recovery versus fresh-boot policy, persisted down suppression,
  logout suppression, and optional enrolled-account boot resume

Checkpoint: both modes meet the network acceptance matrix. Document the absence
of a kill-switch guarantee and the exact management exceptions.

## 5. Cloud add/remove and diagnostics

- [ ] Implement named regional add/capacity using existing endpoints
- [ ] Preserve conservative unknown creation results and no automatic retries
- [ ] Implement explicit-consent removal, fresh authorization, inactive-target
  check, pre-dispatch durable eviction, and post-success warning precedence
- [ ] Verify target identity across account changes, concurrent down, missing
  config/disabled region, lost response, daemon restart, and stale index recovery
- [ ] Add read-only Linux doctor probes with existing report/exit semantics,
  including a server-reachability warning that suggests refresh

Checkpoint: full public command surface except installed-runtime update, with
compatible NDJSON and safe diagnostics. Cloud mutation validation uses isolated
test accounts/clients rather than ordinary production inventory.

## 6. Installation, runtime update, and release

- [ ] Build amd64/arm64 assets and signed manifests for `linux-v1.0.0`
- [ ] Implement inspectable shell installer, architecture/capability checks,
  explicit optional dependency installation, UID enrollment, and private state
- [ ] Install versioned releases with an atomic `current` switch, then restart
  the controller and netd. Wait briefly for running operations first
- [ ] Prove netd restarts adopt a running tunnel without disconnecting
- [ ] Implement update as restart-to-installed-version, with no-op,
  `--allow-disconnect` for journal format changes, same-client reconnect, and
  a persisted update record that survives the controller restart
- [ ] Migrate stored state forward on start and refuse downgrades across a
  storage format change
- [ ] Keep JSON version/build strings mapped to the same release version
- [ ] Implement owned-resource uninstall and opt-in data purge without deleting
  cloud clients or shared distro packages
- [ ] Run contract differential checks, targeted `scripts/test.sh` validation,
  and the real Ubuntu VM matrix, recording versions and sanitized evidence
- [ ] Publish support wording and user/operations docs only after evidence exists

Checkpoint: all macOS CLI commands have meaningful Linux behavior. No disabled
update stub or untested distro claim counts as parity. Additional distributions,
P2P, direct netlink, encrypted-secret integration, remote revocation, backend
idempotency, and a kill switch are separate follow-up work.
