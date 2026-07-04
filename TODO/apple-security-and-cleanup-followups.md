# Apple Security And Cleanup Follow-Ups

Implementation order:

1. [x] Centralize Apple WireGuard config secret storage.
   - Move full WireGuard configs/private keys out of app-group JSON cache and `NETunnelProviderProtocol.providerConfiguration`.
   - Store the full config in a shared Keychain access group with device-only accessibility if compatible with the packet tunnel lifecycle.
   - Keep only config identifiers, display metadata, and a config hash/staleness marker in local cache and provider preferences.
   - Update `CloudGatewayConfigManager`, `CloudGatewayConfigCache`, `GatewayProviderConfiguration`, and `PacketTunnelProvider`.
   - Hard cutoff: no migration or plaintext cleanup for pre-Keychain installs. Pre-cutoff tunnels are unsupported and must be reinstalled from remote state.
   - Implementation notes: [Apple Config Secret Storage](apple-config-secret-storage.md).
   - Implemented with `AfterFirstUnlockThisDeviceOnly` Keychain storage and metadata-only app-group/provider preferences; signed-device reconnect verification remains manual.

2. [x] Document the Apple config-storage design.
   - Record where the full config is allowed to live.
   - Record the accessibility class, backup behavior, app group/access group expectations, and packet tunnel lookup flow.

3. [x] Update API docs for required `clientName`.
   - `POST /clients` now requires non-blank `clientName`.
   - Remove the stale default-name behavior from `docs/api-contract.md`.

4. [x] Update iOS/admin sync docs.
   - iOS admin sync can display and share the full peer audit log.
   - Document that the log can contain user emails, client names, client IDs, public keys, tunnel IPs, statuses, and removed-peer details.

5. [x] Keep admin Firestore config visibility as intentional.
   - Admin reads of `Instances` include `wireguardConfig` by design for current web/admin workflows.
   - Revisit only if admin config visibility policy changes.

6. [x] Keep `httpx2` dev dependency as intentional.
   - Do not replace with `httpx`; it is used for internal dependency needs.

7. [x] Optional future hardening: disabled provisioned users in Firestore rules.
   - Rules now require a non-disabled `Users/{uid}` doc in addition to `UserRoles/{uid}`.
   - Keep tests covering provisioned disabled users.
   - Revisit deprovisioning semantics when the product adds a deprovision workflow.

8. [x] Optional production-origin check.
   - `www.gocloudlaunch.com` currently canonicalizes away before app API calls.
   - If hosting behavior changes, canonicalize `www.` in `apiEndpoints.ts` or enforce an edge redirect.
