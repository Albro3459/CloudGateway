# macOS update and lifecycle review

Review of stack #18 at mac-cli HEAD `5ba539b7`, covering PR17 (`origin/main..mac-refactor-to-controller-architecture`) and PR16 (`mac-refactor-to-controller-architecture..HEAD`) as integrated code. Static review only. No tests, builds, app/VPN execution, SSH, or git mutations.

## Confirmed findings

### P2: Historical release baselines fail the new Mach-service packaging check

- Location: /Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py:144 and /Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py:213
- Layer: PR17 controller refactor
- Trigger: Prepare the first release of this stack using `--previous-distributed-app` with a signed release built from the original packaging, whose extension uses the fixed Mach service `group.com.gocloudlaunch.gateway.macos.tunnel`
- Impact: Release preparation exits with `Mach service mismatch` before archiving. The mandatory baseline cannot be accepted, so the supported upgrade release workflow is blocked. `--initial-distribution` is explicitly prohibited for an already distributed extension
- Evidence: `extension_baseline()` calls `verify_app(app)`, which runs the current verifier with `--developer-id`. The verifier now requires `NEMachServiceName == APP_GROUP + ".tunnel." + CFBundleVersion`. The extension plist at `origin/main` contains the fixed service name, without a build suffix (/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayTunnel/Info.plist:37). The baseline must retain its original signed bytes, so editing its plist is not a valid workaround. /Users/alexbrodsky/GitHub/CloudGateway/docs/apple-macos-release.md:109 also promises historical packaging compatibility
- Assumption: The selected latest distributed app predates the build-specific Mach endpoint. The incompatibility is confirmed directly from the old and new source, without inspecting a distributed binary
- Fix direction: Add a baseline-specific validation policy that accepts the historical fixed Mach endpoint while retaining Developer ID, team, identifier, signature, and artifact checks. Keep the build-specific endpoint requirement for newly prepared releases

## Coverage

Completed the assigned static review. No additional confirmed P1/P2 findings in the update state machine, activation adapter, or menu integration.

- Durable reservation/confirmation, restart reconciliation, two-record recovery, receipt retention, revocation fallback, captured reconnect intent, readiness deadlines, and reconnect cancellation: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacManagedUpdateWorkflow.swift and /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacManagedUpdateStatus.swift
- Activation ownership, orphan recovery, boot changes, live request fencing, readiness tokens, and terminal receipts: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacExtensionUpdateOrchestrator.swift
- App replacement, drain admission, startup ordering, stop/revocation admission, and background activation effects: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacUpdateLifecycle.swift, /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift, and /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift
- Production activation/replacement identity and idle checks: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayExtensionActivationCoordinator.swift
- CLI accepted-output-before-confirmation ordering, pending approval/restart results, and operation recovery guidance: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLIUpdate.swift
- Menu automatic/manual update submission and frontend confirmation/presentation: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift, /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacMenuUpdates.swift, and /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacFrontendClient.swift
- Supporting update storage and stop/reconnect boundaries: /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift, /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift, /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift, and /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacVPNProfileAdapter.swift
- Independent app/extension versions, extension artifact policy, historical baseline verification, and packaged CLI verification: /Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py, /Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py, /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway.xcodeproj/project.pbxproj, and /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayTunnel/Info.plist

Compared both stack layers and the original packaging. Read relevant existing test source for intended behavior without executing it. Checked documented limitations in /Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md, /Users/alexbrodsky/GitHub/CloudGateway/docs/apple-known-issues.md, and /Users/alexbrodsky/GitHub/CloudGateway/docs/apple-macos-release.md.

No functional validation was performed. Actual Apple approval/reboot behavior and distributed artifact contents remain unverified, as requested. Domain authorization and IPC protocol/security review belong to the other assigned reviewers.
