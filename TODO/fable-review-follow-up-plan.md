# Apple Review Follow-up Plan

Scope: `apple` branch, focused on the iOS app, CloudGatewayKit, packet tunnel extension, and the one backend account-deletion item surfaced during the review.

## Decision Summary

| # | Decision | Priority | Notes |
|---|---|---:|---|
| 1 | Fix | High | Rollback can delete the keychain secret used by the currently installed tunnel. |
| 2 | Fix | High | Parser and tunnel conversion errors can expose WireGuard key material. |
| 3 | Fix | Low | Malformed remote `regionId` can crash URL construction; fix defensively even though repro has been elusive. |
| 4 | Ignore | None | Showing connecting as connected is intentional to match Apple's immediate Control Center behavior. |
| 5 | Ignore for now | None | Backend origin fallback is acceptable while there is only one environment. |
| 6 | Fix loud failure | Medium | The hardcoded access group is correct, but missing/unexpanded configuration should fail loudly. |
| 7 | Ignore | None | Not valid. Swift 5 flattens `try?` optionals, and tests cover the fallback. |
| 8 | Fix | Medium | Generic error handling marks remote refresh unavailable after unrelated local failures. |
| 9 | Ignore | None | With 1-3 regions, parallelizing capacity fetches is likely premature. |
| 10 | Fix | Medium | One NetworkExtension preferences load should be enough for status refresh. |

## Planned Work

### 1. Protect Existing Keychain Secrets During Install Rollback

Problem: `CloudGatewayConfigManager.install()` saves the config secret before installing the tunnel. If `installTunnel` fails and the new snapshot uses the same `secretReference` as the existing installed snapshot, the catch block deletes that shared secret. The old tunnel preference may still point at the same keychain account, so the next packet tunnel start can fail with keychain item not found.

Answer to the open question: in this failure case, the new install does not complete. The issue is that the existing install can remain present while its keychain secret has been removed.

Plan:
- In the rollback path, only delete `snapshot.secretReference` when it differs from `oldReference`.
- Add/update a CloudGatewayKit test for failed reinstall of an unchanged config.
- Keep the existing success-path cleanup of old changed secrets.

### 2. Redact WireGuard Key Material From Errors

Problem: `GatewayWireGuardConfigParser.ParseError` stores raw invalid private keys and pre-shared keys in associated values. `PacketTunnelProvider.startTunnel` passes thrown errors to NetworkExtension, so stringified errors may reach system logs.

Plan:
- Change key-related parse errors so they do not carry raw private key or pre-shared key values.
- Keep non-secret validation context where useful, such as field names or redacted reason labels.
- Update tests that currently assert exact raw key values in thrown errors.
- Check packet tunnel conversion errors too, especially private key and pre-shared key branches.

### 3. Harden Regional URL Construction

Problem: `regionalAPIURL(regionId:path:)` force unwraps `components.url` after building the host from API/Firestore-derived `regionId`. A malformed value can crash.

Plan:
- Validate and normalize the remote-derived region identifier before URL construction.
- Strip an accidental `www.` prefix if it ever appears; that should not be coming from the API, but it is harmless to normalize before validation.
- Prefer explicit host construction from the expected production shape, such as `<regionId>.gocloudlaunch.com`, after validating `regionId`.
- Do not route regional API requests to `wg.<regionId>.gocloudlaunch.com`.
- Make URL creation throwing or otherwise surface a normal app error instead of force-unwrapping.
- Keep this low priority, but fix it defensively.

### 4. Keep Connecting Display Behavior

Decision: no change. The app intentionally treats `.connecting` as visually on/connected because Apple Control Center flips immediately and NetworkExtension status updates are coarse.

### 5. Leave Backend Origin Fallback Alone For Now

Decision: no change while CloudGateway has only one environment.

Note: if staging or production-like parallel environments are introduced later, revisit `_origin_host()` before sharing bearer tokens across regional API calls.

### 6. Fail Loudly On Missing Keychain Access-group Configuration

Problem: `cloudGatewayKeychainAccessGroup()` falls back to `CRQWDQ7QQR.com.gocloudlaunch.gateway` when `CGKeychainAccessGroup` is missing, empty, or unexpanded. That can hide a signing/build-setting problem and cause keychain entitlement failures later.

Clarification: `CRQWDQ7QQR.com.gocloudlaunch.gateway` is the correct production access group. The issue is not the value itself; the issue is silently using it when the Info.plist/build setting is missing or failed to expand.

Plan:
- Confirm how `$(CLOUDGATEWAY_KEYCHAIN_ACCESS_GROUP)` resolves for app and tunnel targets under normal local builds.
- Make missing, empty, or unexpanded access-group configuration fail loudly instead of silently falling back.
- Keep app and tunnel entitlements aligned with the runtime provider configuration.

### 7. Ignore Role Nested Optional Finding

Decision: no change. The claim depends on old Swift behavior. This project uses Swift 5 mode, where `try?` flattens optional results, so:

```swift
role = (try? await service.fetchUserRole(uid: user.uid)) ?? access.role
```

falls back to `access.role` when the Firestore role read succeeds with nil.

### 8. Narrow Remote-refresh-unavailable Warnings

Problem: `run()` calls `markRemoteRefreshUnavailable()` for any signed-in error. That stamps installed configs with an offline/stale warning even after unrelated failures such as local VPN start refusal, grant-access validation, or install validation.

Plan:
- Only mark remote refresh unavailable for failures from refresh/load-remote-state paths or network/API refresh failures.
- Keep local VPN failures focused on the local error message.
- Add/update ViewModel tests for a non-refresh failure not stamping stale warning text.

### 9. Do Not Parallelize Region Capacity Fetches Now

Decision: no change. There will only be 1-3 regions, so parallelizing this path is not worth the complexity unless real latency data says otherwise.

### 10. Batch NetworkExtension Preference Loads For Status Refresh

Problem: `refreshStatus()` calls `installedStatus(for:)` for each installed snapshot, and each status call runs `NETunnelProviderManager.loadAllFromPreferences()`. With multiple installed configs, one refresh does K preference loads.

Answer to the open question: yes, one load is the optimal direction. Load all managers once, then match every installed snapshot against that in-memory list.

Plan:
- Add a tunnel-manager API that returns statuses for multiple identifiers from one preferences load, or add an internal helper on `GatewayVPNManager` that batches lookup.
- Keep single-identifier APIs where they are useful for start/stop/remove.
- Add/update tests to verify refresh asks for statuses in one batched operation.

## Suggested Order

1. Fix key leakage.
2. Fix keychain rollback deletion.
3. Fix bogus stale warnings.
4. Batch status preference loads.
5. Investigate keychain access-group fallback.
6. Harden malformed region URL construction.
