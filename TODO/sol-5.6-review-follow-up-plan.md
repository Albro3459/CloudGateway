# Sol 5.6 Review Follow-Up Plan

Plan to resolve the GPT 5.6 Sol code review of the `apple` PR
(`743e500..HEAD`). Decisions below reflect the maintainer's chosen approach for
each finding. Items marked **Ignore** are intentionally not being changed and are
recorded so they are not re-raised.

Scope to implement: findings **3, 1, 4b, 6, 5, 9, 11, 12**.
Skipped (see Ignore): **2, 7, 8, 10**.

The app has not shipped. Assume **no existing users and no installed builds**, so
no data migration or backwards-compatibility work is required anywhere below.

---

## Security

### 3. iOS must not persist WireGuard private keys in Firestore's disk cache - DONE
**Decision:** Must fix. Keychain is the only place secret material may live at
rest. The default Firestore instance uses on-disk persistence, so every fetched
`Instances` document (each containing a client `wireguardConfig` with the private
key) is cached to disk, and an admin fetch caches *every* user's config. No clear
of legacy persistence is needed - there are no released installs to migrate.

**Approach:**
- Configure the shared Firestore instance with memory-only cache **before its
  first use**. Replace the implicit `Firestore.firestore()` with an instance
  whose `FirestoreSettings.cacheSettings = MemoryCacheSettings()`.
- `private let db = Firestore.firestore()` is a stored property initialized at
  type-load; move initialization into an explicit setup that runs before any
  query (e.g. assign settings in the service initializer / a one-time configure
  step invoked right after `FirebaseApp.configure()`), so the memory cache is in
  place before the first read.
- No `clearPersistence()` call required (no prior installs).
- Verify no other code path constructs a second default `Firestore.firestore()`
  instance that would reintroduce disk caching.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayFirebaseService.swift:82`
  (`db` initialization) - build the instance with `MemoryCacheSettings`.
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayApp.swift:12` - ensure Firestore
  settings are applied immediately after `FirebaseApp.configure()` and before any
  service performs a read.

---

## Correctness / Lifecycle

### 1. Block deleting a config while its own tunnel is connected (iOS) - DONE
**Decision:** Nothing to do on web (web does not route its own traffic). On iOS,
do **not** allow deleting a config the device is actively connected to. The user
must disconnect first (connecting to another config also disconnects this one).
Once disconnected, the `DELETE` travels over the normal network and its response
returns instead of being blackholed by the full-tunnel route.

**Approach:**
- Determine "connected to this config" from `tunnelStatuses[clientId]` in the
  connected family (`.connected`, `.connecting`, `.reasserting`) - reuse the
  existing classification already used at `CloudGatewayViewModel.swift:133` /
  `:779` / `:894`.
- When the user taps Delete on a row whose tunnel is in that family, present an
  informational alert ("Disconnect this VPN before deleting its config.") instead
  of the destructive confirm alert - or disable the Delete affordance for that
  row and surface the same guidance.
- **Account deletion has the same root cause:** the API removes all account peers
  before responding, so a connected tunnel blackholes that response too. Since
  there is no alternate config to switch to, stop the active tunnel and await
  `.disconnected` before issuing `DELETE /account` (or block account deletion
  while connected with the same guidance).

**Files:**
- `Frontend/Apple/iOS/CloudGateway/ContentView.swift:154-168` (delete confirm
  alert) and `:685-687` (row Delete action) - gate on connected status.
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayViewModel.swift:597`
  (`deleteClient`) - guard/early-out (or expose a `isConnected(_ option:)`
  helper) so a connected config cannot be deleted.
- Account-deletion path (`deleteAccount*` in `CloudGatewayViewModel.swift`) -
  disconnect + await `.disconnected` before the request.

### 4b. Sign out Google Sign-In on logout (iOS) - DONE
**Decision:** Keeping the local tunnel alive across logout is intentional and
stays. Only the Google credential leak is a real gap: Firebase `signOut()` does
not clear Google Sign-In's saved Keychain session, so Google tokens survive
CloudGateway logout.

**Approach:**
- Call `GIDSignIn.sharedInstance.signOut()` during logout in addition to
  `Auth.auth().signOut()`.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayFirebaseService.swift:325`
  (`signOut()`) - add the Google sign-out.

### 6. Delete the Keychain secret before clearing its cache reference (iOS) - DONE
**Decision:** Fix the ordering so a failed secret deletion is retryable.

**Approach:**
- In `removeTunnel`, the current order is `removeTunnel` -> `cache.clear` ->
  `deleteConfig(secret)`. The `secretReference` is captured locally first, so an
  in-memory retry still has it, but if `deleteConfig` throws and the app restarts,
  state reloads from the already-cleared cache and the reference is lost ->
  orphaned Keychain secret forever. Reorder to: remove profile -> **delete secret**
  -> `cache.clear` -> state cleanup, so a failed secret delete leaves the cache
  entry intact for a reboot to retry.
- Apply the same reordering to the missing-profile reconciliation path, which
  also clears the cache before the (currently `try?`-suppressed) secret delete.

**Files:**
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/CloudGatewayConfigManager.swift:126-138`
  (`removeTunnel`) - delete secret before `cache.clear`.
- `:150-156` (missing-profile path in `refreshStatus`) - same ordering.

### 5. Web login must check apex account access before regional capacity (Web) - DONE
**Decision:** Agreed. Run `checkAccountAccess` first so the intended access
message shows instead of a generic authentication failure.

**Approach:**
- Each regional capacity call requires provisioning; a missing role disables the
  Auth user and revokes tokens (`auth.py:51`), which turns the later access check
  into a generic auth failure. Perform the apex `checkAccountAccess` before
  fetching per-region capacities in the login flow.

**Files:**
- `Frontend/Web/src/pages/Login.tsx:74` - move `checkAccountAccess` ahead of the
  regional capacity fetches.

---

## UI / Polish

### 9. Fix destructive/auth modal UI and accessibility gaps - DONE
**Decision:** Low priority but fine to fix.

**Approach:**
- iOS: sheet operations render progress/errors behind the presented sheet and use
  a fixed, non-scrollable height for account deletion; large Dynamic Type or the
  keyboard can hide controls. Make the account-deletion sheet content scrollable
  and surface in-progress/error state on the presented sheet rather than behind
  it.
- Web: the link and delete overlays lack dialog semantics, focus trapping, focus
  restoration, and Escape handling. Add `role="dialog"`/`aria-modal`, trap and
  restore focus, and close on Escape.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/ContentView.swift:1138` (`DeleteAccountView`) -
  scrollable content, error/progress on the sheet.
- `Frontend/Web/src/pages/Home.tsx:1027` (link overlay), `:1211` (delete overlay) -
  dialog semantics, focus trap/restore, Escape.

### 11. Reduce tunnel-health filesystem churn (iOS extension) - DONE
**Decision:** Optional but cheap; implement. Currently the extension writes the
health file on every 5s poll (~17,280 atomic writes/day for a continuously
connected VPN).

**Approach:**
- Keep evaluating every 5s so dead-tunnel notifications still fire promptly on
  transitions, but only **write** the snapshot when (a) the health state changed,
  or (b) the last persisted write is older than a heartbeat interval (~15s, safely
  inside the existing 30s `freshnessWindow`). This keeps readers seeing a fresh
  snapshot while cutting steady-state writes to ~5,760/day worst case, fewer when
  stable.

**Files:**
- `Frontend/Apple/iOS/CloudGatewayTunnel/PacketTunnelProvider.swift:134`
  (`pollTunnelHealth`) - gate the `store.write` on transition-or-heartbeat.
- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayKit/GatewayTunnelHealthStore.swift:10`
  (`freshnessWindow`) - reference for the heartbeat bound.

### 12. Request notification permission in context, not at launch (iOS) - DONE
**Decision:** Valid finding (dropped from the final 11 only as lowest-priority,
not because it was wrong). Requesting authorization in `didFinishLaunching`
prompts guests who have never installed a VPN, with no context; iOS shows the
system prompt only once, so a no-context prompt can lower opt-in for the
dead-tunnel alert that matters later.

**Approach:**
- Move `requestAuthorization` out of `didFinishLaunchingWithOptions` and trigger
  it after the first VPN install/connect action, with brief explanatory UI. Keep
  the delegate assignment at launch. The in-app dead-tunnel warning already covers
  users who decline.

**Files:**
- `Frontend/Apple/iOS/CloudGateway/CloudGatewayApp.swift:16-18` - remove the
  launch-time `requestAuthorization`; keep `center.delegate = self`.
- Install/connect flow (`CloudGatewayViewModel` / `ContentView`) - request
  authorization at first install/connect with context.

---

## Ignore - intentionally not changing

- **2. Account deletion can leave a WireGuard credential live indefinitely (API).**
  Requires simultaneous API-down + WireGuard-UDP-up; probability is low and the
  boot/manual `cloudgateway-sync-peers` reconcile is the backstop. Accept the
  residual risk; no tombstones/periodic reconcile. `routes.py:644`.
- **7. VPN status can remain stale until refresh (iOS).** Acceptable: reload /
  foreground re-snapshots status and updates config state. Not adding an
  `NEVPNStatusDidChange` observer. `GatewayVPNManager.swift:85`.
- **8. Region capacity loads serially (iOS).** 1-3 regions today; N x timeout is
  bounded and small. Not parallelizing.
  `CloudGatewayFirebaseService.swift:375`.
- **10. Privacy policy omits server-side private-key storage (Web).** The stored
  config is CloudGateway operational data. Not a security bug; not disclosing in
  the policy. Revisit only if a formal privacy pass is done.
  `PrivacyPolicy.tsx:103`.
