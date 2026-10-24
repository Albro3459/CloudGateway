import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Darwin
import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class CloudGatewayMacControllerService {
    private struct LegacyState: Decodable {
        let extensionUpdate: CloudGatewayMacExtensionUpdateOrchestrator.LegacyAttempt?
        let finishedExtensionUpdates: [UUID: Date]?
    }

    // periphery:ignore - Holding the lock prevents a second Firebase owner for the service lifetime
    private let ownership: CloudGatewayMacControllerOwnership
    private let runtime: CloudGatewayMacPassiveRuntime<CloudGatewayMacControllerRuntime>
    private let orchestrator: CloudGatewayMacControllerOrchestrator
    private let server: CloudGatewayMacControllerServer

    init(identity: CloudGatewayMacBuildIdentity) throws {
        let directory = CloudGatewayMacControllerRuntime.directory
        ownership = try CloudGatewayMacControllerOwnership(directory: directory)
        let team = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
        let data = try CloudGatewayMacControllerUpdateStorage.load(directory: directory)
        let storedUpdates: CloudGatewayMacExtensionUpdateOrchestrator.StoredState
        if let updates = try CloudGatewayMacControllerUpdateStorage.load(directory: directory, record: .extensionUpdates) {
            storedUpdates = try JSONDecoder().decode(CloudGatewayMacExtensionUpdateOrchestrator.StoredState.self, from: updates)
        } else if let data {
            let legacy = try JSONDecoder().decode(LegacyState.self, from: data)
            storedUpdates = try .init(legacyAttempt: legacy.extensionUpdate,
                                      finishedExtensionUpdates: legacy.finishedExtensionUpdates ?? [:])
        } else { storedUpdates = .init() }
        let updates = try CloudGatewayMacExtensionUpdateOrchestrator(
            stored: storedUpdates, bootSession: Self.bootSession
        ) {
            try CloudGatewayMacControllerUpdateStorage.save(JSONEncoder().encode($0), directory: directory,
                                                            record: .extensionUpdates)
        }
        let requests = try CloudGatewayMacControllerRequests(data: data) { data in
            // Preserve migrated updates before replacing an older combined receipt file
            try CloudGatewayMacControllerUpdateStorage.save(JSONEncoder().encode(updates.stored), directory: directory,
                                                            record: .extensionUpdates)
            try CloudGatewayMacControllerUpdateStorage.save(data, directory: directory)
        }
        weak var orchestratorReference: CloudGatewayMacControllerOrchestrator?
        let runtime = CloudGatewayMacPassiveRuntime {
            let runtime = CloudGatewayMacControllerRuntime()
            runtime.controller.onAuthenticationChange = { [weak orchestrator = orchestratorReference] in
                orchestrator?.authenticationDidChange()
            }
            runtime.controller.start()
            return runtime
        }
        self.runtime = runtime
        let installedURL = URL(fileURLWithPath: "/Applications/CloudGateway.app")
        let activation = CloudGatewayExtensionActivationCoordinator(
            installedURL: installedURL, teamIdentifier: team, appIdentity: identity
        )
        let managed = CloudGatewayMacManagedUpdateWorkflow(directory: directory)
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { state, canUpdate in
                .init(snapshot: runtime.require().controller.snapshot(), setupState: state,
                      canUpdateExtension: canUpdate)
            },
            hasPendingWork: { runtime.initialized?.controller.hasPendingWork ?? false },
            perform: { request, complete in
                switch request.action {
                case .connect:
                    return runtime.require().controller.connectClient(identifier: request.identifier, onCompletion: complete)
                case .disconnectClient:
                    guard let identifier = request.identifier else { return false }
                    return runtime.require().controller.disconnectClient(identifier: identifier, onCompletion: complete)
                case .removeClient:
                    guard let identifier = request.identifier else { return false }
                    return runtime.require().controller.removeClient(identifier: identifier, onCompletion: complete)
                case .turnOff: return runtime.require().controller.turnOff(onCompletion: complete)
                case .signIn:
                    let state = runtime.require().controller.snapshot()
                    guard !state.isRestoringSession, !state.isAuthSettling else {
                        complete(.failed(.busy))
                        return false
                    }
                    runtime.require().controller.signIn()
                case .cancelSignIn: runtime.require().controller.cancelSignIn()
                case .signOut:
                    complete(runtime.require().controller.signOut() ? .completed(warning: nil) : .failed(.credentialsUnavailable))
                    return true
                case .refresh: runtime.require().controller.refresh()
                case .menuWillOpen: runtime.require().controller.menuWillOpen()
                default: return false
                }
                complete(.completed(warning: nil))
                return true
            },
            session: { runtime.initialized?.controller.session },
            refresh: { await runtime.require().controller.awaitRefresh() },
            prepareClient: {
                guard let context = runtime.require().controller.clientCreationContext() else {
                    throw CloudGatewayMacControllerFailure.busy
                }
                let regions = try await runtime.require().controller.loadCreateRegions(context: context)
                return CloudGatewayMacPreparedClient(regions: regions) { region, name, complete in
                    runtime.require().controller.createClient(regionId: region, clientName: name, context: context, onCompletion: complete)
                }
            },
            setSetupState: { runtime.initialized?.controller.setSetupState($0) },
            hasAnyActiveTunnel: { try await runtime.require().hasAnyActiveTunnel() },
            installedIdentity: {
                await Task.detached {
                    try? CloudGatewayMacSignedBundle.installed(at: installedURL, teamIdentifier: team,
                                                               bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier)
                }.value
            },
            extensionIdentity: {
                try CloudGatewayMacSignedBundle.installed(
                    at: installedURL.appendingPathComponent(
                        "Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension"
                    ), teamIdentifier: team, bundleIdentifier: "com.gocloudlaunch.gateway.tunnel.macos"
                )
            },
            ping: { identity in
                let client = try CloudGatewayMacXPCSecretClient(teamIdentifier: team, extensionBuild: identity.build)
                return try await client.ping()
            }, registrationReadiness: { await ExtensionRegistrationProbe.readiness() },
            initializeRuntime: { _ = runtime.require() },
            isRuntimeInitialized: { runtime.initialized != nil },
            diagnostics: {
                let snapshot = runtime.initialized?.controller.snapshot()
                async let registration = ExtensionRegistrationProbe.diagnosticReadiness()
                async let preferences = CloudGatewayMacPassivePreferences.read()
                var extensionState = await registration
                if extensionState == .enabled {
                    let response = try? await CloudGatewayMacInventoryRequest.perform(timeout: .seconds(1)) {
                        let target = try await Task.detached(priority: .utility) {
                            try CloudGatewayMacSignedBundle.installed(at: installedURL.appendingPathComponent(
                                "Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension"),
                                teamIdentifier: team, bundleIdentifier: "com.gocloudlaunch.gateway.tunnel.macos")
                        }.value
                        try Task.checkCancellation()
                        let client = try CloudGatewayMacXPCSecretClient(teamIdentifier: team, extensionBuild: target.build)
                        return CloudGatewayMacControllerDiagnostics.extensionReadiness(installed: target, observed: try await client.ping())
                    }
                    if let response { extensionState = response }
                }
                return await .init(runtimeInitialized: snapshot != nil, access: snapshot?.domain.access,
                             credentials: snapshot?.domain.credentials, extensionState: extensionState,
                             preferences: preferences,
                             regionId: snapshot?.domain.clients.first?.regionId)
            },
            login: { request in
                let controller = runtime.require().controller
                switch request.action {
                case .beginLogin: return controller.beginLogin(attemptId: request.id, origin: request.loginOrigin ?? .cli)
                case .loginStatus: return request.contextId.map { controller.loginStatus(attemptId: $0) }
                case .cancelLogin: return request.contextId.map { controller.cancelLogin(attemptId: $0) }
                default: return nil
                }
            },
            userActivity: { runtime.require().controller.recordUserActivity(refreshIfStale: $0) },
            refreshInventoryIfDue: { runtime.initialized?.controller.refreshInventoryIfDue() },
            setAutomaticInventoryRefreshAllowed: {
                runtime.initialized?.controller.setAutomaticInventoryRefreshAllowed($0, discardDeferred: $1)
            },
            managedUpdateObservation: { try await runtime.require().controller.managedUpdateObservation() },
            reconnectClient: { identifier, complete in
                runtime.require().controller.connectClient(identifier: identifier, displacingOtherProfiles: false,
                                                           onCompletion: complete)
            },
            cancelManagedReconnect: { identifier in
                await runtime.require().controller.cancelManagedReconnect(identifier: identifier)
            },
            activateExtension: { id, target, event in
                activation.activate(attemptId: id, target: target, onEvent: event)
            },
            activationIsPending: { activation.isPending }
        )
        let orchestrator = CloudGatewayMacControllerOrchestrator(identity: identity, effects: effects,
                                                                 requests: requests, extensionUpdates: updates,
                                                                 managedUpdates: managed)
        orchestratorReference = orchestrator
        self.orchestrator = orchestrator
        server = try CloudGatewayMacControllerServer(teamIdentifier: team, appVersion: identity.version,
                                                     appBuild: identity.build, buildIdentity: identity) {
            await orchestrator.handle($0)
        }
    }

    func run() {
        Task { [weak self] in
            guard let self else { return }
            await orchestrator.bootstrapManagedUpdate()
            server.resume()
            while !Task.isCancelled {
                await orchestrator.tick()
                if orchestrator.canExit, server.invalidateIfIdle() {
                    runtime.initialized?.shutdown()
                    exit(EXIT_SUCCESS)
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private static func bootSession() -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        var length = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}

private final class ExtensionRegistrationProbe: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CloudGatewayMacControllerDiagnostics.ExtensionState, Never>?
    private let request = OSSystemExtensionRequest.propertiesRequest(
        forExtensionWithIdentifier: "com.gocloudlaunch.gateway.tunnel.macos", queue: .global()
    )

    static func readiness() async -> CloudGatewayMacSetupState {
        switch await diagnosticReadiness() {
        case .ready, .enabled: return .updateRequired
        case .awaitingApproval: return .awaitingApproval
        case .incompatible, .replacementBlocked: return .updateRequired
        case .disabled, .missing, .unknown: return .required
        }
    }

    static func diagnosticReadiness() async -> CloudGatewayMacControllerDiagnostics.ExtensionState {
        let probe = ExtensionRegistrationProbe()
        return await withCheckedContinuation { continuation in
            probe.continuation = continuation
            probe.request.delegate = probe
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { probe.finish(.unknown) }
            OSSystemExtensionManager.shared.submitRequest(probe.request)
        }
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let installed = properties.filter { !$0.isUninstalling }
        if installed.contains(where: \.isAwaitingUserApproval) { finish(.awaitingApproval) }
        else { finish(installed.isEmpty ? .missing : installed.contains(where: \.isEnabled) ? .enabled : .disabled) }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) { finish(.unknown) }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { finish(.awaitingApproval) }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {}

    func request(
        _ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction { .cancel }

    private func finish(_ state: CloudGatewayMacControllerDiagnostics.ExtensionState) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: state)
    }
}

private enum CloudGatewayMacPassivePreferences {
    static func read() async -> CloudGatewayMacControllerDiagnostics.Evidence {
        do {
            _ = try await CloudGatewayMacInventoryRequest.perform(timeout: .seconds(2)) {
                _ = try await CloudGatewayMacVPNProfileAdapter().installedProfiles()
                return true
            }
            return .available
        } catch CloudGatewayMacVPNProfileError.invalidProfile { return .invalid }
        catch CloudGatewayMacVPNProfileError.duplicateProfile { return .invalid }
        catch CloudGatewayMacConfigError.invalidConfig { return .invalid }
        catch { return .unknown }
    }
}
