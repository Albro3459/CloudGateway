# macOS menu, inventory, and config review

Status: source review complete on branch `apple`, 2026-10-02

Scope: menu composition, Firebase inventory, account metadata cache, VPN profile
adapter, config installation/switching, and setup state. Review only, no
production edits or live VPN commands.

## Confirmed findings

### MENU-01, P1: known admin downgrade still restores other owners' cached configs

* Location: `Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift:222`
  and `:235-244`,
  `Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift:5-13`
* Trigger: an admin previously installs another owner's client. The account
  is downgraded to `user`. Refresh successfully receives that lower role from
  `/auth/check-access`, then a Firestore query times out or loses connectivity
* Result: the offline catch loads every config in the UID cache. It ignores
  the already-confirmed lower role. Installed snapshots retain no `ownerUid`
  or authorization role, so filtering by installing account UID also keeps
  clients that were accessible only through former admin privileges
* Impact: the downgraded user sees and can start another owner's retained
  client through the app. The secret service checks macOS UID/config ownership,
  so it still accepts the former admin's committed secret and issues a grant.
  This is a known privilege reduction, beyond an unobserved offline change
* Smallest fix: persist the role that authorized the cache. On receiving a
  lower role, invalidate the prior admin cache before awaiting inventory, and
  allow fallback only after a complete refresh under the current role.
  Preserving owned configs instead needs cached owner UID metadata and filtering
* Evidence: `CloudGatewayMacInventoryService.swift:79` applies owner filtering
  for `user`, and `:94` checks the same ownership after mapping. The controller
  loses that distinction in its transport-failure path. Cache snapshots only
  retain the installing account and `accessAllowed`. Source trace confirmed,
  no live role change or VPN start performed. Existing offline tests cover
  denial versus transport, but do not cover a known role downgrade followed
  by a transport failure

## Reviewed behavior

* Signed-out menus deliberately omit VPN controls. The README and
  `TODO/macos-app.md` explicitly require retaining the tunnel after sign-out
  and allowing System Settings to stop it
* Account caches use separate hashed UID directories. Cache authorization
  binds installed metadata to the latest accessible config hash, and a
  successful refresh prunes rotated or revoked clients
* Commands stop active CloudGateway profiles before requesting a single-use
  grant. Cancellation checks precede profile replacement and live starts.
  Referenced secrets finish commit after cancellation so saved profiles do
  not lose their secret
* Setup readiness/version handling overlaps MAC-01 in `macos-review.md`.
  Also check that Refresh preserves a pending restart requirement
* Failed denial persistence alone does not establish a later offline bypass.
  The Firebase custom-token session writes an unsettled marker before sign-out
  and suppresses `currentUser` when sign-out fails. A new process retries
  cleanup before restoring a user. Excluded as an unconfirmed compound failure

## Validation

Source and existing host-free tests reviewed. No builds, tests, or live VPN
actions run by this review agent. Root agent owns validation.

Cross-process/macOS-user command ordering remains a signed runtime limit.
The coordinator serializes one actor, and the system extension owns one shared
secret service. Apple's [NETunnelProviderManager documentation](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager?changes=__3&language=objc)
describes app-scoped preference visibility and one enabled enterprise VPN.
That prevents assuming two independent starts result in two active tunnels.
The exact stop/save/start interaction across processes and user sessions has
not been reproduced, so it is not listed as a confirmed defect. Add concurrent
user-session commands to the isolated signed runtime checks.
