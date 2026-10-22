import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

@MainActor
final class CloudGatewayMacMenuClient {
    var onChange: (() -> Void)?
    var onReplacement: ((CloudGatewayMacBuildIdentity) -> Void)?
    private(set) var isCurrentBuild = false
    private(set) var snapshot: CloudGatewayMacControllerView?
    private(set) var errorMessage: String?
    private let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
    private let identity: CloudGatewayMacBuildIdentity
    private var pollTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var instanceId: UUID?
    private var isShuttingDown = false
    private var connections: [UUID: CloudGatewayMacControllerClient] = [:]

    init(identity: CloudGatewayMacBuildIdentity) {
        self.identity = identity
    }

    func start() {
        guard pollTask == nil, !isShuttingDown else { return }
        pollTask = Task { [weak self] in
            var retryDelay = 1
            while !Task.isCancelled {
                guard let self, !isShuttingDown else { return }
                do {
                    let handshake = try await request(.lifecycle)
                    guard let lifecycle = handshake.lifecycle else { throw CloudGatewayMacControllerFailure.invalidRequest }
                    isCurrentBuild = lifecycle.state == .current && lifecycle.running == identity && lifecycle.installed == identity
                    if let installed = lifecycle.installed, installed != identity {
                        snapshot = nil
                        errorMessage = "Opening the updated CloudGateway app…"
                        onChange?()
                        onReplacement?(installed)
                    }
                    guard isCurrentBuild else { throw CloudGatewayMacControllerFailure.busy }
                    _ = try await request(.snapshot)
                    retryDelay = 1
                } catch {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    snapshot = nil
                    isCurrentBuild = false
                    errorMessage = message(for: error)
                    onChange?()
                    if error as? CloudGatewayMacControllerFailure != .incompatibleVersion {
                        do {
                            let installed = URL(fileURLWithPath: "/Applications/CloudGateway.app")
                            _ = try CloudGatewayMacSignedBundle.installed(
                                at: installed, teamIdentifier: teamIdentifier,
                                bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier
                            )
                            let launcher = try CloudGatewayMacControllerLauncher(
                                executableURL: installed.appendingPathComponent("Contents/MacOS/CloudGateway"),
                                directory: CloudGatewayMacControllerRuntime.directory
                            )
                            _ = try await launcher.bootstrap()
                        } catch {
                            errorMessage = message(for: error)
                            onChange?()
                        }
                    }
                    retryDelay = min(retryDelay * 2, 10)
                }
                do { try await Task.sleep(for: .seconds(retryDelay)) }
                catch { return }
            }
        }
    }

    func shutdown() {
        isShuttingDown = true
        pollTask?.cancel()
        pollTask = nil
        for connection in connections.values { connection.invalidate() }
        connections.removeAll()
        onChange = nil
        onReplacement = nil
    }

    func request(
        _ action: CloudGatewayMacControllerRequest.Action,
        id: UUID = UUID(),
        identifier: String? = nil,
        regionId: String? = nil,
        clientName: String? = nil,
        contextId: UUID? = nil
    ) async throws -> CloudGatewayMacControllerReply {
        guard !isShuttingDown else { throw CancellationError() }
        guard action == .lifecycle || isCurrentBuild else { throw CloudGatewayMacControllerFailure.busy }
        try Task.checkCancellation()
        sequence &+= 1
        let currentSequence = sequence
        let connection = try CloudGatewayMacControllerClient(
            teamIdentifier: teamIdentifier, appVersion: identity.version, appBuild: identity.build, buildIdentity: identity
        )
        let connectionId = UUID()
        connections[connectionId] = connection
        defer {
            connection.invalidate()
            connections.removeValue(forKey: connectionId)
        }
        let reply = try await connection.request(CloudGatewayMacControllerRequest(
            action: action, id: id, identifier: identifier, regionId: regionId, clientName: clientName,
            contextId: contextId, appVersion: identity.version, appBuild: identity.build, buildIdentity: identity
        ))
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        if let failure = reply.error { throw failure }
        if let state = reply.snapshot, currentSequence >= appliedSequence {
            appliedSequence = currentSequence
            if instanceId != nil, instanceId != reply.instanceId {
                // A replacement controller invalidates every outstanding Add Client context
                snapshot = nil
                onChange?()
            }
            instanceId = reply.instanceId
            snapshot = state
            errorMessage = nil
            onChange?()
        }
        return reply
    }

    func message(for error: Error) -> String {
        if error as? CloudGatewayMacControllerLaunchError == .installationRequired {
            return "Install CloudGateway in /Applications to start the controller"
        }
        switch error as? CloudGatewayMacControllerFailure {
        case .incompatibleVersion:
            return "CloudGateway is updating. Waiting for the installed controller"
        case .invalidRequest:
            return "The older controller needs a one-time restart to enable synchronized updates"
        case .outcomeUnknown:
            return "The previous operation could not be confirmed. Check VPN status before trying again"
        case .busy:
            if !isCurrentBuild { return "CloudGateway is updating. Finishing current operations…" }
            return "Another operation is in progress. Wait for it to finish and try again"
        case .rejected:
            return "Account or client list changed. Refresh and try again"
        case .timeout:
            return "Controller request timed out. Refresh status before trying the action again"
        default:
            return "Unable to reach the controller. Reconnecting…"
        }
    }
}
