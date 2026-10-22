import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Darwin
import Foundation
import SystemExtensions

@MainActor
final class CloudGatewayMacControllerService {
    private struct LegacyState: Decodable {
        let extensionUpdate: CloudGatewayMacExtensionUpdateOrchestrator.LegacyAttempt?
        let finishedExtensionUpdates: [UUID: Date]?
    }

    // periphery:ignore - Holding the lock prevents a second Firebase owner for the service lifetime
    private let ownership: CloudGatewayMacControllerOwnership
    private let runtime: CloudGatewayMacControllerRuntime
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
        let runtime = CloudGatewayMacControllerRuntime()
        self.runtime = runtime
        let installedURL = URL(fileURLWithPath: "/Applications/CloudGateway.app")
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { state, canUpdate in
                .init(snapshot: runtime.controller.snapshot(), setupState: state,
                      canUpdateExtension: canUpdate)
            },
            hasPendingWork: { runtime.controller.hasPendingWork },
            perform: { request, complete in
                switch request.action {
                case .connect:
                    return runtime.controller.connectClient(identifier: request.identifier, onCompletion: complete)
                case .turnOff: return runtime.controller.turnOff(onCompletion: complete)
                case .signIn:
                    let state = runtime.controller.snapshot()
                    guard !state.isRestoringSession, !state.isAuthSettling else {
                        complete(.failed(.busy))
                        return false
                    }
                    runtime.controller.signIn()
                case .cancelSignIn: runtime.controller.cancelSignIn()
                case .signOut:
                    complete(runtime.controller.signOut() ? .completed(warning: nil) : .failed(.credentialsUnavailable))
                    return true
                case .refresh: runtime.controller.refresh()
                case .menuWillOpen: runtime.controller.menuWillOpen()
                default: return false
                }
                complete(.completed(warning: nil))
                return true
            },
            session: { runtime.controller.session },
            refresh: { await runtime.controller.awaitRefresh() },
            prepareClient: {
                guard let context = runtime.controller.clientCreationContext() else {
                    throw CloudGatewayMacControllerFailure.busy
                }
                let regions = try await runtime.controller.loadCreateRegions(context: context)
                return CloudGatewayMacPreparedClient(regions: regions) { region, name, complete in
                    runtime.controller.createClient(regionId: region, clientName: name, context: context, onCompletion: complete)
                }
            },
            setSetupState: { runtime.controller.setSetupState($0) },
            hasAnyActiveTunnel: { try await runtime.hasAnyActiveTunnel() },
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
            }, registrationReadiness: { await ExtensionRegistrationProbe.readiness() }
        )
        let orchestrator = CloudGatewayMacControllerOrchestrator(identity: identity, effects: effects,
                                                                 requests: requests, extensionUpdates: updates)
        self.orchestrator = orchestrator
        server = try CloudGatewayMacControllerServer(teamIdentifier: team, appVersion: identity.version,
                                                     appBuild: identity.build, buildIdentity: identity) {
            await orchestrator.handle($0)
        }
    }

    func run() {
        runtime.controller.start()
        server.resume()
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await orchestrator.tick()
                if orchestrator.canExit, server.invalidateIfIdle() {
                    runtime.shutdown()
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
    private var continuation: CheckedContinuation<CloudGatewayMacSetupState, Never>?
    private let request = OSSystemExtensionRequest.propertiesRequest(
        forExtensionWithIdentifier: "com.gocloudlaunch.gateway.tunnel.macos", queue: .global()
    )

    static func readiness() async -> CloudGatewayMacSetupState {
        let probe = ExtensionRegistrationProbe()
        return await withCheckedContinuation { continuation in
            probe.continuation = continuation
            probe.request.delegate = probe
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { probe.finish(.required) }
            OSSystemExtensionManager.shared.submitRequest(probe.request)
        }
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let installed = properties.filter { !$0.isUninstalling }
        if installed.contains(where: \.isAwaitingUserApproval) { finish(.awaitingApproval) }
        else { finish(installed.contains(where: \.isEnabled) ? .updateRequired : .required) }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) { finish(.required) }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { finish(.awaitingApproval) }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {}

    func request(
        _ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction { .cancel }

    private func finish(_ state: CloudGatewayMacSetupState) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: state)
    }
}
