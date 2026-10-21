import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import Foundation

@MainActor
final class CloudGatewayMacMenuClient {
    var onChange: (() -> Void)?
    private(set) var snapshot: CloudGatewayMacControllerView?
    private(set) var errorMessage: String?
    private let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    private var pollTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var instanceId: UUID?
    private var isShuttingDown = false
    private var connections: [UUID: CloudGatewayMacControllerClient] = [:]

    func start() {
        guard pollTask == nil, !isShuttingDown else { return }
        pollTask = Task { [weak self] in
            var retryDelay = 1
            while !Task.isCancelled {
                guard let self, !isShuttingDown else { return }
                do {
                    _ = try await request(.snapshot)
                    retryDelay = 1
                } catch {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    snapshot = nil
                    errorMessage = message(for: error)
                    onChange?()
                    if error as? CloudGatewayMacControllerFailure != .incompatibleVersion {
                        do {
                            guard let executable = Bundle.main.executableURL else {
                                throw CloudGatewayMacControllerLaunchError.installationRequired
                            }
                            let launcher = try CloudGatewayMacControllerLauncher(
                                executableURL: executable, directory: CloudGatewayMacControllerRuntime.directory
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
    }

    func request(
        _ action: CloudGatewayMacControllerRequest.Action,
        identifier: String? = nil,
        regionId: String? = nil,
        clientName: String? = nil,
        contextId: UUID? = nil
    ) async throws -> CloudGatewayMacControllerReply {
        guard !isShuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
        sequence &+= 1
        let currentSequence = sequence
        let connection = try CloudGatewayMacControllerClient(
            teamIdentifier: teamIdentifier, appVersion: appVersion, appBuild: appBuild
        )
        let connectionId = UUID()
        connections[connectionId] = connection
        defer {
            connection.invalidate()
            connections.removeValue(forKey: connectionId)
        }
        let reply = try await connection.request(CloudGatewayMacControllerRequest(
            action: action, identifier: identifier, regionId: regionId, clientName: clientName,
            contextId: contextId, appVersion: appVersion, appBuild: appBuild
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
            return "Controller version changed. Quit CloudGateway, wait 60 seconds, then reopen the installed app"
        case .busy:
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
