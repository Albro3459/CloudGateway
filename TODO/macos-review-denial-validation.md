# Authorization-denial validation

Static review at mac-cli HEAD `5ba539b7`, covering PR17 and PR16 as integrated code. No tests, snippets, builds, app, VPN, SSH, or Firebase requests were run. Only this document is edited.

## Verdict

**Confirmed P1, with a narrow timing prerequisite.** A completed Clients permission-denied can be discarded when the Regions read fails first in tuple evaluation. The controller then takes its offline fallback rather than invalidating authorization. The role-commit path protects an already-observed downgrade, but does not protect a downgrade after an access check returned `.admin`.

## Evidence

- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:79`: the client query is unfiltered for the role returned by the access check. Lines 81 and 88 launch independent async-let reads. Line 96 reads the tuple in Regions, Clients order.
- Swift's [SE-0317, tuple evaluation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md#declaring-async-let-with-patterns) expands an awaited tuple into individually awaited elements, evaluated one by one. Its [error propagation section](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md#async-let-error-propagation) explains that an async-let error is surfaced by explicitly reading that value, and implicit cleanup discards errors. The [implicit-await discussion](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md#implicit-async-let-awaiting) explains cancellation and implicit awaiting on scope exit. Applying those documented rules here: a Regions throw prevents the explicit Clients read, and cleanup does not replace the Regions error with Clients denial. This is source reasoning, not an executed compiler experiment.
- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacInventoryRequest.swift:7`: each read defaults to a ten-second timeout classified as `.offline`. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:156` receives listener errors, and line 166 classifies them. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacInventoryError.swift:28` maps Firestore permission-denied to `.accessDenied`.
- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:406`: checkAccess completes before observeRole is committed at lines 408–413 and before fetchOptions at line 415. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift:101` invalidates only when the observed role is `.user` and the prior cached role differs. An observed `.admin` leaves an existing admin cache intact.
- `/Users/alexbrodsky/GitHub/CloudGateway/Backend/Firebase/firestore.rules:89`: an unfiltered Instances collection-group query loses authorization when the account loses admin status. Enabled Regions remain readable by a provisioned user at line 42, so a region transport delay and a Clients authorization error are distinct outcomes.
- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:424`: the offline catch reloads the saved configs and sets hasAuthorizedInventory at line 435. The denial catch at line 443, including cache.deny at line 449 and signOut at line 451, is skipped.

- `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift:684`: offline connect eligibility accepts an installed active config. The connect path at line 771 rechecks the same retained cache at lines 772–777, then calls configs.connect at line 787. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift:235` checks the local secret/profile and requests a start grant. `/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacSecretService.swift:72` checks committed-secret ownership, not the cloud role. There is no additional cloud check in this path that would repair the discarded denial.

## Concrete trigger and qualifications

1. The account previously authorized and installed another user's config while it was an admin. Its account cache still has that authorized config and `.admin` role.
2. A refresh's access check reads the old admin role and returns `.admin`. The local role commit therefore does not invalidate the cache.
3. Admin status changes before the Instances read is authorized. Clients finishes with permission-denied, while Regions obtains no server snapshot and times out, or returns an offline-classified transport failure.
4. The tuple's Regions read throws `.offline`. The completed Clients denial is discarded at scope exit. Offline fallback restores the still-authorized admin cache.

This does **not** apply when checkAccess already returns `.user`: observeRole clears the old admin cache before fetchOptions begins. A successful Regions read also exposes the Clients denial normally. A later access check returning `.user` invalidates the old admin cache, so this does not claim that every future refresh preserves it. The review confirms behavior for the stated pair of completed outcomes. It does not establish how often Firestore delivers this asymmetric network outcome in deployment.

The impact is continued local authorization of cached configs after an authorization denial was actually received. It does not claim new server-side read access, retrieval of previously uncached secrets, or guaranteed VPN reachability after peer revocation. Those limits do not remove the local fail-open behavior.

## Fix direction

Capture both read outcomes without losing either error and let authorization denial dominate a transport failure, or propagate a denial immediately while canceling its sibling. Merely swapping tuple elements transfers the same problem to a denied Regions read. Preserve the existing role-commit invalidation for downgrades already observed by checkAccess.

## Layer attribution and coverage

The concurrent fetch and tuple join were introduced in PR17, replacing the original sequential Regions-then-Clients reads. The original could fall back after a Regions failure, but it had not launched Clients yet and therefore had not received a denial to discard. PR16 leaves the inventory service and account-cache code unchanged. The integrated HEAD still routes the offline result into the retained-cache connect path described above.

Checked async-let semantics against primary Swift documentation, inventory request timeout/error mapping, role-commit/cache invalidation, controller offline/denial and connect branches, extension start-grant checks, Firebase rules, the access-check response, and both layer diffs for the relevant code. This was a focused validation of the existing report, not a fresh whole-stack review. No additional findings were sought or confirmed. Main agent should retain the timing and reachability qualifications when integrating this finding.
