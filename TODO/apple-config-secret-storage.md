# Apple Config Secret Storage

Status: Planned. Supports [Apple Security And Cleanup Follow-Ups](apple-security-and-cleanup-followups.md).

Goal: make the full WireGuard config, including the private key and optional preshared key, live in one durable local secret store. App-group files and Network Extension preferences should contain only nonsecret lookup and staleness metadata.

## Decision

Use a shared Keychain access group for the iOS app and packet tunnel extension. Store each full WireGuard config as a generic password item with:

* `kSecClassGenericPassword`
* `kSecAttrAccessGroup`: shared CloudGateway Keychain access group, present in both app and tunnel extension entitlements
* `kSecAttrAccessible`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
* `kSecAttrSynchronizable`: omitted/false
* `kSecAttrService`: a CloudGateway-specific service name, for example `com.gocloudlaunch.gateway.wireguard-config`
* `kSecAttrAccount`: a stable lookup key, preferably `wireguard-config/<clientId>/<configHash>`
* `kSecValueData`: UTF-8 WireGuard config text

`AfterFirstUnlockThisDeviceOnly` is the intended tradeoff:

* Works for normal background tunnel starts after the user unlocks the device once after boot.
* Does not migrate through encrypted backup or iCloud Keychain.
* Does not sync to other devices.
* Fails before the first unlock after a reboot. This is acceptable for CloudGateway.

Do not use `WhenUnlockedThisDeviceOnly`; it can break background reconnects while the phone is locked. Do not use `AlwaysThisDeviceOnly`; Apple deprecates/strongly discourages always-accessible secrets.

## Reconnect Behavior

The packet tunnel extension should be able to read the Keychain item while the device is locked if the user has already unlocked once since boot.

Expected to work after first unlock:

* Wi-Fi/cellular loss followed by network return.
* Airplane Mode on/off.
* Wi-Fi to cellular or cellular to Wi-Fi transitions.
* System relaunch of the packet tunnel extension.
* User turning VPN on from Settings or Control Center.
* Future On Demand reconnects, if On Demand rules are added.

Expected to fail until user unlocks:

* Device reboots.
* User has not unlocked once.
* System tries to start the VPN before that first unlock.
* Tunnel extension attempts to read the WireGuard config from Keychain and receives an unavailable/interaction error.

After the first unlock, the same tunnel should be startable by the app, Settings, Control Center, or Network Extension background lifecycle events.

## Storage Shape

Allowed durable copies of full config:

* Shared Keychain item only.

Not allowed:

* `CloudGatewayConfigSnapshot` app-group JSON.
* `NETunnelProviderProtocol.providerConfiguration`.
* UserDefaults.
* Logs, diagnostics, or app-visible debug text.

Allowed in app-group cache and provider preferences:

* `clientId`
* `regionId`
* client display name
* region display name
* config status
* `readAt`
* `updatedAt`
* `configHash`, computed from normalized full config
* Keychain account/reference string

`providerConfiguration` should be reduced to values the packet tunnel needs to find the secret:

* app group identifier, if still needed for metadata
* tunnel identifier/client ID
* Keychain service name
* Keychain account/reference
* config hash/version marker

## Implementation Notes

Add a secret-store abstraction in `CloudGatewayKit`, for example:

```swift
public protocol CloudGatewayConfigSecretStoring: Sendable {
    func saveConfig(_ config: GatewayWireGuardConfig, for reference: GatewayConfigSecretReference) async throws
    func loadConfig(for reference: GatewayConfigSecretReference) async throws -> GatewayWireGuardConfig
    func deleteConfig(for reference: GatewayConfigSecretReference) async throws
}
```

Keep the concrete SecItem implementation outside UI code. The iOS app and packet tunnel extension can both use it because both link `CloudGatewayKit`.

Refactor models:

* Replace `CloudGatewayConfigSnapshot.wireGuardConfig` with `configHash` and `secretReference`.
* Keep `CloudGatewayClient.wireGuardConfig` as the remote/app-facing install source for now.
* Change `CloudGatewayConfigSelection.configMatches` to compare remote normalized config hash to installed snapshot hash.
* Change `CloudGatewayConfigSnapshot.tunnelConfiguration()` so it no longer carries raw config.

Install ordering should avoid half-installed state:

1. Normalize and validate remote WireGuard config.
2. Compute `configHash`.
3. Save full config to Keychain under the new account/reference.
4. Save/update `NETunnelProviderManager` with only metadata and Keychain reference.
5. Save app-group snapshot metadata.
6. Clean old Keychain item for that client if the reference changed.

Remove ordering:

1. Stop tunnel if needed by existing behavior.
2. Remove tunnel preferences.
3. Delete app-group metadata.
4. Delete Keychain item.

The packet tunnel startup path should:

1. Read `NETunnelProviderProtocol.providerConfiguration`.
2. Extract client ID and Keychain reference.
3. Read full config from shared Keychain.
4. Parse into `TunnelConfiguration`.
5. Start WireGuard.

If Keychain read fails because the device is before first unlock, return a clear local error. Do not fall back to a cached plaintext config.

## Migration

Existing installs may have raw configs in both `installed-configs.json` and provider preferences.

Migration path:

1. On app launch/local-state load, read existing snapshots.
2. For each snapshot with `wireGuardConfig`, validate and store it in Keychain.
3. Write a new metadata-only snapshot with `configHash` and `secretReference`.
4. Re-save the matching `NETunnelProviderManager` with metadata-only provider configuration.
5. Rewrite `installed-configs.json` without raw config values.

Keep the migration idempotent. If a Keychain item already exists and matches the hash, treat it as success.

If migration cannot read or validate the old config, mark that installed config as needing reinstall from remote state rather than preserving plaintext fallback behavior.

## macOS Forward Compatibility

The same `CloudGatewayKit` secret-store protocol should serve the future macOS app and macOS packet tunnel extension.

macOS notes:

* Add the shared Keychain access group entitlement to both the app and extension.
* Use `kSecUseDataProtectionKeychain: true` in the macOS SecItem implementation so access group and accessibility semantics align with the iOS path.
* Keep `kSecAttrSynchronizable` false; VPN private keys are device-bound secrets.
* Keep platform-specific SecItem flags inside the concrete secret store, not in config-manager logic.

## Entitlements

Add Keychain Sharing to:

* `Frontend/Apple/iOS/CloudGateway/CloudGateway.entitlements`
* `Frontend/Apple/iOS/CloudGatewayTunnel/CloudGatewayTunnel.entitlements`
* future macOS app entitlements
* future macOS packet tunnel extension entitlements

Use one Team ID-prefixed access group value for the app/extension pair. Keep the existing App Group entitlement for shared nonsecret metadata and any other file coordination.

## Validation

Docs-only changes need manual review. Implementation should be validated with:

* `swift test` or the existing Apple package gate for model/secret-store tests.
* Signed device test for real Network Extension startup.
* Manual scenarios:
  * install/update client config
  * start from app
  * start from Settings/Control Center
  * lock device, lose/restore network
  * Airplane Mode on/off
  * reboot, try VPN before first unlock if possible, then unlock and retry

